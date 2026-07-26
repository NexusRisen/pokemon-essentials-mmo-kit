require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Audit item 4: the switches/variables/self-switches DETECTION shadow. The server
# records the absolute snapshot and flags a self-switch REWIND (one-shot events
# re-armed = the NPC-gift/TM/key-item re-farm). It never rejects, and it must not
# flag the things that legitimately move backwards (temp switches, countdowns).
class FlagStateTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:flag_snapshots].delete rescue nil
    # dependents first: monsters/rolls hold FKs to accounts (no cascade — audit rows
    # deliberately survive account deletion), so a bare accounts.delete would fail.
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "fl-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @fs = PEMK::FlagState.new(@db, logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def snap(switches: [], variables: {}, self_switches: [])
    { switches: switches, variables: variables, self_switches: self_switches }
  end

  def test_records_an_absolute_snapshot
    status, flags = @fs.apply_flags(@a, snap(switches: [3, 1], variables: { "10" => 5 },
                                             self_switches: ["5:2:A"]), 1)
    assert_equal :ack, status
    assert_empty flags
    row = @fs.snapshot(@a)
    assert_equal [1, 3], row[:switches].to_a          # normalized: unique + sorted
    assert_equal({ "10" => 5 }, row[:variables].to_h)
    assert_equal ["5:2:A"], row[:self_switches].to_a
    assert_equal 1, row[:last_seq]
  end

  def test_stale_snapshot_is_a_dup_and_never_overwrites
    @fs.apply_flags(@a, snap(switches: [1, 2, 3]), 5)
    status, = @fs.apply_flags(@a, snap(switches: []), 4)   # replayed older
    assert_equal :dup, status
    assert_equal [1, 2, 3], @fs.snapshot(@a)[:switches].to_a
  end

  # THE signal: a batch of one-shot markers going OFF is a save rollback.
  def test_self_switch_rewind_is_flagged
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A", "2:7:A", "3:1:A"]), 1)
    status, flags = @fs.apply_flags(@a, snap(self_switches: ["1:1:A"]), 2)   # 3 cleared
    assert_equal :ack, status
    assert_includes flags, "rewind"
    assert @fs.snapshot(@a)[:flagged]
    assert(@logs.any? { |l| l.include?("SUSPECT rewind") }, @logs.inspect)
  end

  def test_a_single_cleared_self_switch_is_tolerated
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A"]), 1)
    _, flags = @fs.apply_flags(@a, snap(self_switches: ["1:1:A"]), 2)   # 1 cleared
    assert_empty flags, "one deliberate reset must not open a report"
  end

  # Switches turning off and counters decreasing happen constantly in honest play
  # (temp flags, countdowns, event resets) — recorded, never judged.
  def test_switch_off_and_variable_decrease_are_recorded_not_flagged
    @fs.apply_flags(@a, snap(switches: [1, 2, 3], variables: { "4" => 100 }), 1)
    _, flags = @fs.apply_flags(@a, snap(switches: [1], variables: { "4" => 2 }), 2)
    assert_empty flags
    refute @fs.snapshot(@a)[:flagged]
    assert(@logs.any? { |l| l.include?("regression") }, @logs.inspect)
  end

  # A snapshot over the cap is stored but marked, and — the subtle half — the NEXT
  # snapshot can't be judged against it either: entries the truncated one had to drop
  # would read as cleared and fake a rewind. It just re-establishes a clean baseline.
  def test_a_truncated_snapshot_is_never_judged_in_either_direction
    big = (1..(PEMK::FlagState::MAX_ENTRIES + 1)).map { |i| "1:#{i}:A" }
    _, flags = @fs.apply_flags(@a, snap(self_switches: big), 1)
    assert_equal ["truncated"], flags
    assert @fs.snapshot(@a)[:truncated]

    _, flags = @fs.apply_flags(@a, snap(self_switches: []), 2)   # would look like a huge rewind
    assert_equal ["truncated"], flags                            # not judged against a bad baseline
    refute @fs.snapshot(@a)[:truncated], "the fresh full snapshot becomes a clean baseline"

    # ...and from that clean baseline, detection works again
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A", "1:3:A"]), 3)
    _, flags = @fs.apply_flags(@a, snap(self_switches: []), 4)
    assert_includes flags, "rewind"
  end

  def test_hostile_shapes_are_rejected
    assert_equal :rej, @fs.apply_flags(@a, snap(switches: [99_999]), 1).first        # out of range
    assert_equal :rej, @fs.apply_flags(@a, snap(switches: ["x"]), 1).first           # wrong type
    assert_equal :rej, @fs.apply_flags(@a, snap(variables: { "abc" => 1 }), 1).first # bad key
    assert_equal :rej, @fs.apply_flags(@a, "nope", 1).first                          # not a hash
    assert_equal 0, @db[:flag_snapshots].count
  end

  # THE RECONNECT BUG: Sync.reset zeroes every channel seq on a new socket, and the
  # server treats seq <= last_seq as a dup — so without the server advertising its
  # high-water (flags_seq) and the client adopting it, the channel goes permanently
  # silent after the first reconnect. This test pins the server half of that contract.
  def test_snapshot_exposes_last_seq_so_a_reconnect_can_resume
    @fs.apply_flags(@a, snap(switches: [1]), 7)
    assert_equal 7, @fs.snapshot(@a)[:last_seq]

    # a reconnect restarting at 1 WOULD be dropped as stale...
    assert_equal :dup, @fs.apply_flags(@a, snap(switches: [1, 2]), 1).first
    # ...which is exactly why the client must resume above the advertised high-water
    assert_equal :ack, @fs.apply_flags(@a, snap(switches: [1, 2]), 8).first
    assert_equal [1, 2], @fs.snapshot(@a)[:switches].to_a
  end

  def test_non_integer_variables_are_dropped_not_rejected
    status, = @fs.apply_flags(@a, snap(variables: { "3" => "quest", "4" => 7 }), 1)
    assert_equal :ack, status
    assert_equal({ "4" => 7 }, @fs.snapshot(@a)[:variables].to_h)
  end
end

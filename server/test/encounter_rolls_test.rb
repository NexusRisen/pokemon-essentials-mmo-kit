require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer D D3.2: the persisted encounter-roll claim-check (record -> mark_caught ->
# claim) and the Monsters provenance binding (origin wild_caught / wild / client).
class EncounterRollsTest < Minitest::Test
  MINT = { "species" => "SPINARAK", "level" => 12, "pid" => 12_345,
           "iv" => [31, 20, 15, 10, 5, 0], "shiny" => false }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:encounter_rolls].delete rescue nil
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "er-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "er-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @rolls = PEMK::EncounterRolls.new(@db)
    @logs  = []
    @mons  = PEMK::Monsters.new(@db, CAPS, logger: ->(m) { @logs << m }, rolls: @rolls)
  end

  CAPS = { uid_req_max: 64, party_max: 6, level_max: 100 }.freeze

  def teardown
    @db&.disconnect
  end

  def entry(tmp: 1, pid: 12_345, species: :SPINARAK, level: 12)
    { tmp: tmp, species: species, level: level, pid: pid, egg: false }
  end

  # --- the roll lifecycle -----------------------------------------------------------
  def test_record_claim_and_caught_stamp
    @rolls.record(@a, MINT, 5, "LandNight")
    assert_equal :wild, @rolls.claim(@a, "SPINARAK", 12_345)[:label]  # claimed, not caught
    assert_nil @rolls.claim(@a, "SPINARAK", 12_345)                   # already claimed

    @rolls.record(@a, MINT, 5, "LandNight")                            # a second roll
    assert @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    assert_equal :wild_caught, @rolls.claim(@a, "SPINARAK", 12_345)[:label]
  end

  def test_claim_is_account_scoped_and_identity_exact
    @rolls.record(@a, MINT, 5, "Land")
    assert_nil @rolls.claim(@b, "SPINARAK", 12_345)                   # another account
    assert_nil @rolls.claim(@a, "RATTATA", 12_345)                    # wrong species
    assert_nil @rolls.claim(@a, "SPINARAK", 99_999)                   # wrong pid
    assert_equal :wild, @rolls.claim(@a, "SPINARAK", 12_345)[:label]  # species+pid match works
  end

  # Level is NOT part of the claim key: a mon that leveled between catch and (a delayed)
  # first sweep still claims its roll instead of mislabeling "client".
  def test_claim_tolerates_level_drift
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    e = entry(pid: 12_345, level: 14)                                  # leveled up before the sweep
    _, grants = @mons.mint_batch(@a, [e])
    assert_equal "wild_caught", @db[:monsters].where(id: grants[0][:uid]).get(:origin)
  end

  # With two matching rolls, claim prefers the CAUGHT one (never coin-flips to :wild).
  def test_claim_prefers_caught_rolls
    @rolls.record(@a, MINT, 5, "Land")                                 # uncaught roll (older)
    @rolls.record(@a, MINT, 5, "Land")                                 # second roll ...
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)                     # ... stamped (newest uncaught)
    assert_equal :wild_caught, @rolls.claim(@a, "SPINARAK", 12_345)[:label]
  end

  # --- D8 STEP 2: the roll->mon link + birth states ----------------------------------

  def test_claim_returns_seed_context_and_mint_stamps_the_link
    @rolls.record(@a, MINT, 5, "Land", seed: 777)
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, grants = @mons.mint_batch(@a, [entry(pid: 12_345)])
    uid = grants[0][:uid]
    roll = @db[:encounter_rolls].where(account_id: @a).first
    assert_equal uid, roll[:claimed_monster_uid]           # the link, stamped in the claim
    assert_equal 777, roll[:battle_seed]
  end

  def test_seeded_claim_births_provisional_when_resim_on
    mons_on = PEMK::Monsters.new(@db, CAPS, rolls: @rolls, resim: :on)
    @rolls.record(@a, MINT, 5, "Land", seed: 777)
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, grants = mons_on.mint_batch(@a, [entry(pid: 12_345)])
    row = @db[:monsters].where(id: grants[0][:uid]).first
    assert_equal "provisional", row[:verify_state]
    assert_equal "active", row[:status]                    # provisional, NOT quarantined
  end

  def test_condemned_roll_births_quarantined_when_resim_on
    mons_on = PEMK::Monsters.new(@db, CAPS, rolls: @rolls, resim: :on)
    @rolls.record(@a, MINT, 5, "Land", seed: 777)
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    @db[:encounter_rolls].where(account_id: @a).update(condemned_at: Time.now)   # walk refuted it
    _, grants = mons_on.mint_batch(@a, [entry(pid: 12_345)])
    row = @db[:monsters].where(id: grants[0][:uid]).first
    assert_equal "quarantined", row[:status]               # born condemned — no claim/verdict race
    assert_equal "walk_mismatch", row[:quarantine_reason]
    refute_nil row[:quarantined_at]
  end

  def test_unseeded_or_off_births_stay_none_active
    # resim :off (the default @mons): seeded roll -> still none/active
    @rolls.record(@a, MINT, 5, "Land", seed: 777)
    _, grants = @mons.mint_batch(@a, [entry(pid: 12_345)])
    row = @db[:monsters].where(id: grants[0][:uid]).first
    assert_equal "none", row[:verify_state]
    assert_equal "active", row[:status]

    # resim :on but UNSEEDED roll (rng was off at mint time) -> none/active too
    mons_on = PEMK::Monsters.new(@db, CAPS, rolls: @rolls, resim: :on)
    @rolls.record(@b, MINT.merge("pid" => 55), 5, "Land")   # no seed
    _, grants = mons_on.mint_batch(@b, [entry(pid: 55)])
    row = @db[:monsters].where(id: grants[0][:uid]).first
    assert_equal "none", row[:verify_state]
  end

  # Boot retention: stale never-fought rolls are pruned; caught/claimed rows are kept.
  def test_prune_drops_only_stale_unfought_rolls
    old = Time.now - (10 * 86_400)
    @rolls.record(@a, MINT, 5, "Land", now: old)                       # stale, never fought
    @rolls.record(@a, MINT.merge("pid" => 2), 5, "Land", now: old)     # stale but caught
    @rolls.mark_caught(@a, "SPINARAK", 12, 2, now: old)
    @rolls.record(@a, MINT.merge("pid" => 3), 5, "Land")               # fresh
    assert_equal 1, @rolls.prune
    pids = @db[:encounter_rolls].select_map(:pid).sort
    assert_equal [2, 3], pids
  end

  # D7: a roll a battle record references must survive the prune — deleting it would
  # SET NULL the record's binding and re-open the seed's single-use constraint.
  def test_prune_keeps_rolls_referenced_by_battle_records
    old = Time.now - (10 * 86_400)
    id = @rolls.record(@a, MINT.merge("pid" => 9), 5, "Land", seed: 4242, now: old)  # stale, unfought...
    @db[:battle_records].insert(account_id: @a, encounter_roll_id: id, mode: "shadow",
                                record: Sequel.blob("x"), replay_status: "pending", created_at: old)
    assert_equal 0, @rolls.prune                                       # ...but corpus-bound -> kept
    assert_equal 1, @db[:encounter_rolls].where(id: id).count
  end

  def test_mark_caught_needs_an_uncaught_roll
    refute @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)             # nothing recorded
    @rolls.record(@a, MINT, 5, "Land")
    assert @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    refute @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)             # already stamped
  end

  # --- provenance binding in the UID mint ---------------------------------------------
  def test_mint_with_a_caught_roll_is_wild_caught
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, grants = @mons.mint_batch(@a, [entry])
    origin = @db[:monsters].where(id: grants[0][:uid]).get(:origin)
    assert_equal "wild_caught", origin
    assert_nil @db[:encounter_rolls].where(account_id: @a, claimed_at: nil).first   # roll claimed
    assert(@logs.any? { |l| l.include?("wild_caught=1") }, @logs.inspect)
  end

  def test_mint_without_a_roll_is_client
    _, grants = @mons.mint_batch(@a, [entry(pid: 777)])               # starter/gift/egg case
    assert_equal "client", @db[:monsters].where(id: grants[0][:uid]).get(:origin)
  end

  def test_replay_keeps_the_original_origin
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, g1 = @mons.mint_batch(@a, [entry])
    _, g2 = @mons.mint_batch(@a, [entry])                              # same nonce -> replay
    assert_equal g1[0][:uid], g2[0][:uid]
    assert_equal "wild_caught", @db[:monsters].where(id: g1[0][:uid]).get(:origin)
  end

  def test_save_copied_clone_labels_client
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, g1 = @mons.mint_batch(@a, [entry(tmp: 1)])                      # the original claims the roll
    _, g2 = @mons.mint_batch(@a, [entry(tmp: 2)])                      # the CLONE (new nonce, same pid)
    assert_equal "wild_caught", @db[:monsters].where(id: g1[0][:uid]).get(:origin)
    assert_equal "client",      @db[:monsters].where(id: g2[0][:uid]).get(:origin)
  end

  def test_mint_without_rolls_collaborator_stays_nil
    plain = PEMK::Monsters.new(@db, { uid_req_max: 64, party_max: 6, level_max: 100 })
    _, grants = plain.mint_batch(@a, [entry(tmp: 9, pid: 42)])
    assert_nil @db[:monsters].where(id: grants[0][:uid]).get(:origin)   # legacy behavior
  end
end

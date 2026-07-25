require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Audit item 5: the per-mon stat block — a FIRST-SIGHT LOCK on the traits the game's
# own rules never change (IVs, shiny, gender), so a counterfeit carrying a valid uid
# stops being invisible. Everything that legitimately changes in play (level, EVs,
# moves, ability, item, nature, species/evolution) is recorded but NEVER judged.
class MonsterBlocksTest < Minitest::Test
  IVS = { "HP" => 20, "ATTACK" => 15, "DEFENSE" => 26,
          "SPECIAL_ATTACK" => 20, "SPECIAL_DEFENSE" => 13, "SPEED" => 4 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_blocks].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "mb-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "mb-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @mb = PEMK::MonsterBlocks.new(@db, logger: ->(m) { @logs << m })
    @nonce = 0
  end

  def teardown
    @db&.disconnect
  end

  def uid_for(account)
    @nonce += 1
    @db[:monsters].insert(owner_account_id: account, issuer_account_id: account, client_nonce: @nonce,
                          species: "PIDGEY", level_at_issue: 5, personal_id: 1000 + @nonce, egg_at_issue: false)
  end

  def mon(uid, **over)
    { uid: uid, species: "PIDGEY", level: 12, ivs: IVS, evs: {}, moves: ["TACKLE"],
      ability: "KEENEYE", nature: "JOLLY", item: nil, shiny: false, gender: 0 }.merge(over)
  end

  def test_first_sight_locks_the_block
    u = uid_for(@a)
    assert_empty @mb.observe(@a, [mon(u)])
    row = @mb.block_for(u)
    assert_equal IVS, row[:ivs].to_h
    refute row[:diverged]
  end

  # --- what MUST be caught ---------------------------------------------------

  def test_iv_decrease_is_a_counterfeit
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    d = @mb.observe(@a, [mon(u, ivs: IVS.merge("ATTACK" => 2))])
    assert_equal 1, d.length
    assert(d[0][:reasons].any? { |r| r.start_with?("iv_attack") }, d.inspect)
    assert @mb.block_for(u)[:diverged]
    assert(@logs.any? { |l| l.include?("SUSPECT") }, @logs.inspect)
  end

  def test_iv_increase_to_a_non_31_value_is_a_counterfeit
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    d = @mb.observe(@a, [mon(u, ivs: IVS.merge("SPEED" => 25))])   # 4 -> 25, not Hyper Training
    refute_empty d
  end

  def test_shiny_flip_and_gender_change_are_counterfeits
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    d = @mb.observe(@a, [mon(u, shiny: true, gender: 1)])
    assert_equal 1, d.length
    assert_equal 2, d[0][:reasons].length
  end

  # A counterfeit must not launder itself by simply repeating the lie.
  def test_a_locked_trait_is_never_overwritten_by_a_divergent_report
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    @mb.observe(@a, [mon(u, ivs: IVS.merge("ATTACK" => 2))])
    refute_empty @mb.observe(@a, [mon(u, ivs: IVS.merge("ATTACK" => 2))])   # still divergent
    assert_equal 15, @mb.block_for(u)[:ivs].to_h["ATTACK"]                  # the lock held
  end

  # --- what must NOT be flagged (the false-positive guard) -------------------

  def test_hyper_training_to_31_is_legal
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    assert_empty @mb.observe(@a, [mon(u, ivs: IVS.merge("ATTACK" => 31))])
  end

  def test_normal_play_changes_are_recorded_not_judged
    u = uid_for(@a)
    @mb.observe(@a, [mon(u)])
    d = @mb.observe(@a, [mon(u, species: "PIDGEOTTO", level: 20, evs: { "HP" => 40 },
                             moves: %w[GUST QUICKATTACK], ability: "TANGLEDFEET",
                             nature: "ADAMANT", item: "ORANBERRY")])
    assert_empty d, "evolution, EVs, moves, ability, nature and items all change legitimately"
    row = @mb.block_for(u)
    assert_equal "PIDGEOTTO", row[:species]           # tracked...
    assert_equal IVS, row[:ivs].to_h                  # ...but the lock is untouched
    refute row[:diverged]
  end

  # --- ownership -------------------------------------------------------------

  def test_only_owned_uids_are_locked_or_judged
    ub = uid_for(@b)
    assert_empty @mb.observe(@a, [mon(ub, ivs: IVS.merge("HP" => 31))])
    assert_nil @mb.block_for(ub), "a client must not create or divert another account's block"
  end

  def test_nil_uid_in_flight_is_skipped
    assert_empty @mb.observe(@a, [mon(nil)])
    assert_equal 0, @db[:monster_blocks].count
  end
end

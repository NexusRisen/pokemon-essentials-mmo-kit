require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer D D6 part 1: per-UID EXP high-water + rollback detection. EXP never decreases
# in normal play, so a reported EXP below the stored high-water is a save-rollback / edit.
class MonsterStatsTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_stats].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "ms-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "ms-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @ms = PEMK::MonsterStats.new(@db)
    @nonce = 0
  end

  def teardown
    @db&.disconnect
  end

  # mint a monsters row owned by +account+, return its uid.
  def uid_for(account)
    @nonce += 1
    @db[:monsters].insert(owner_account_id: account, issuer_account_id: account, client_nonce: @nonce,
                          species: "PIDGEY", level_at_issue: 5, personal_id: 1000 + @nonce, egg_at_issue: false)
  end

  def test_records_and_raises_the_high_water
    u = uid_for(@a)
    assert_empty @ms.observe(@a, [{ uid: u, exp: 500, level: 5 }])
    assert_equal 500, @ms.exp_for(u)
    assert_empty @ms.observe(@a, [{ uid: u, exp: 1_200, level: 7 }])   # legit growth
    assert_equal 1_200, @ms.exp_for(u)
  end

  def test_detects_a_rollback_and_keeps_the_high_water
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 1_200, level: 7 }])
    roll = @ms.observe(@a, [{ uid: u, exp: 500, level: 5 }])           # old save reloaded
    assert_equal [{ uid: u, from: 1_200, to: 500 }], roll
    assert_equal 1_200, @ms.exp_for(u)                                 # high-water NOT downgraded
  end

  # A single no-fault crash re-projects the low EXP on login AND every later frame; the
  # latch reports it ONCE, not once per frame, so one honest event can't flood D5.
  def test_rollback_is_latched_and_only_reported_once_per_high_water
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 1_200, level: 7 }])
    refute_empty @ms.observe(@a, [{ uid: u, exp: 500, level: 5 }])     # first below high-water
    assert_empty @ms.observe(@a, [{ uid: u, exp: 500, level: 5 }])     # re-projected — suppressed
    assert_empty @ms.observe(@a, [{ uid: u, exp: 900, level: 6 }])     # still below — suppressed

    @ms.observe(@a, [{ uid: u, exp: 1_300, level: 8 }])               # re-grinds past — latch clears
    assert_equal 1_300, @ms.exp_for(u)
    roll = @ms.observe(@a, [{ uid: u, exp: 400, level: 4 }])          # a genuinely NEW rollback
    assert_equal [{ uid: u, from: 1_300, to: 400 }], roll             # re-armed, reports again
  end

  def test_equal_exp_is_not_a_rollback
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 1_000, level: 6 }])
    assert_empty @ms.observe(@a, [{ uid: u, exp: 1_000, level: 6 }])   # re-report of the same
  end

  def test_only_owned_uids_are_tracked
    ub = uid_for(@b)                                                   # a mon B owns
    assert_empty @ms.observe(@a, [{ uid: ub, exp: 9_999, level: 50 }]) # A reports it -> ignored
    assert_nil @ms.exp_for(ub)
  end

  def test_ignores_malformed_entries
    u = uid_for(@a)
    assert_empty @ms.observe(@a, [{ uid: u, exp: nil, level: 5 }, { uid: u, exp: -1, level: 5 }, { uid: nil, exp: 5 }])
    assert_nil @ms.exp_for(u)
  end

  def test_multiple_mons_in_one_party
    u1 = uid_for(@a); u2 = uid_for(@a)
    @ms.observe(@a, [{ uid: u1, exp: 800, level: 6 }, { uid: u2, exp: 300, level: 4 }])
    roll = @ms.observe(@a, [{ uid: u1, exp: 900, level: 6 }, { uid: u2, exp: 100, level: 4 }])  # u2 rolled back
    assert_equal [{ uid: u2, from: 300, to: 100 }], roll
    assert_equal 900, @ms.exp_for(u1)
    assert_equal 300, @ms.exp_for(u2)
  end

  # --- D6 part 2: the up-only restore plan --------------------------------------

  def test_corrections_lists_only_below_high_water_mons
    u1 = uid_for(@a); u2 = uid_for(@a)
    @ms.observe(@a, [{ uid: u1, exp: 1_200, level: 7 }, { uid: u2, exp: 500, level: 5 }])
    plan = @ms.corrections(@a, [{ uid: u1, exp: 400, level: 4 },     # below -> restore to 1200
                                { uid: u2, exp: 500, level: 5 }])    # at the high-water -> clean
    assert_equal [{ uid: u1, exp: 1_200, level: 7 }], plan   # :level = at-high-water level (server-internal)
  end

  # The high-water must never MEMORIZE (observe) nor RE-IMPOSE (corrections) an
  # impossible EXP a hacked client once projected: absurd values store CLAMPED.
  def test_observe_clamps_absurd_exp_to_the_sanity_cap
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 2**40, level: 100 }])
    assert_equal PEMK::MonsterStats::FALLBACK_EXP_CAP, @ms.exp_for(u)   # no battle_data -> global cap
    plan = @ms.corrections(@a, [{ uid: u, exp: 100, level: 2 }])
    assert_equal PEMK::MonsterStats::FALLBACK_EXP_CAP, plan[0][:exp]    # restore target is capped too
  end

  def test_exp_cap_uses_the_species_growth_curve_when_battle_data_is_present
    battle = Class.new do
      def species(id)
        { "growth_rate" => "Medium" } if id == "PIDGEY"
      end

      def growth_rate_max_exp(rate)
        1_000_000 if rate == "Medium"
      end
    end.new
    ms = PEMK::MonsterStats.new(@db, battle: battle)
    u = uid_for(@a)
    ms.observe(@a, [{ uid: u, exp: 2**40, level: 100, species: "PIDGEY" }])
    assert_equal 1_000_000, ms.exp_for(u)                               # per-species curve cap
    u2 = uid_for(@a)
    ms.observe(@a, [{ uid: u2, exp: 2**40, level: 100, species: "UNKNOWNMON" }])
    assert_equal PEMK::MonsterStats::FALLBACK_EXP_CAP, ms.exp_for(u2)   # unknown species -> fallback
  end

  def test_corrections_is_empty_when_clean_or_above
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 1_000, level: 6 }])
    assert_empty @ms.corrections(@a, [{ uid: u, exp: 1_000, level: 6 }])   # equal
    assert_empty @ms.corrections(@a, [{ uid: u, exp: 1_500, level: 8 }])   # above (growth)
    assert_empty @ms.corrections(@a, [])                                   # nothing reported
  end

  def test_corrections_ignores_unowned_and_untracked_uids
    ua = uid_for(@a); ub = uid_for(@b)
    @ms.observe(@a, [{ uid: ua, exp: 900, level: 6 }])
    @ms.observe(@b, [{ uid: ub, exp: 900, level: 6 }])
    # A reports B's mon below its high-water -> NOT corrected for A (unowned);
    # an untracked uid (no monster_stats row) -> nothing to restore to.
    untracked = uid_for(@a)
    plan = @ms.corrections(@a, [{ uid: ub, exp: 100, level: 2 }, { uid: untracked, exp: 100, level: 2 }])
    assert_empty plan
  end

  def test_corrections_does_not_write_anything
    u = uid_for(@a)
    @ms.observe(@a, [{ uid: u, exp: 1_200, level: 7 }])
    before = @db[:monster_stats].where(uid: u).first
    @ms.corrections(@a, [{ uid: u, exp: 400, level: 4 }])
    assert_equal before, @db[:monster_stats].where(uid: u).first   # read-only (observe owns writes)
  end
end

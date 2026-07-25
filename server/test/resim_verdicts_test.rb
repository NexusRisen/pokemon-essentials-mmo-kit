require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer D D8 verdict sweep: harness-stamped verdicts -> monster state, on the
# live server. Only walk_mismatch condemns (gated by strikes + FP-storm breaker);
# match certifies; replay `mismatch` never auto-condemns. Idempotent + audited.
class ResimVerdictsTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = acct("rv-a@x.co")
    @b = acct("rv-b@x.co")
    @logs = []
  end

  def teardown; @db&.disconnect; end

  def acct(email)
    @db[:accounts].insert(email: email, password_hash: "x", status: "active", created_at: Time.now)
  end

  def det(mode: :on, strikes: 2)
    PEMK::ResimVerdicts.new(@db, mode: mode, min_strikes: strikes, logger: ->(m) { @logs << m })
  end

  # a caught, minted, provisional mon + its seeded roll + a battle record. Returns
  # [uid, record_id]. status lets us set the record's verdict.
  def caught(account, status:, seed: 1000, verify: "provisional", fp: "aa" * 8, monster_status: "active")
    uid = @db[:monsters].insert(owner_account_id: account, issuer_account_id: account,
                                client_nonce: rand(1 << 40), species: "PIDGEY", level_at_issue: 5,
                                personal_id: rand(1 << 30), egg_at_issue: false, origin: "wild_caught",
                                verify_state: verify, status: monster_status)
    roll = @db[:encounter_rolls].insert(account_id: account, species: "PIDGEY", level: 5,
                                        pid: rand(1 << 30), iv: Sequel.pg_jsonb([0] * 6), shiny: false,
                                        map: 5, enctype: "Land", battle_seed: seed, caught_at: Time.now,
                                        claimed_at: Time.now, claimed_monster_uid: uid, created_at: Time.now)
    rec = @db[:battle_records].insert(account_id: account, encounter_roll_id: roll, mode: "on",
                                      record: Sequel.blob("x"), replay_status: status, engine_fp: fp,
                                      outcome: 4, created_at: Time.now)
    [uid, rec, roll]
  end

  def mon(uid); @db[:monsters].where(id: uid).first; end
  def rec_action(id); @db[:battle_records].where(id: id).get(:enforcement_action); end

  # --- verify: match -> verified -----------------------------------------------
  def test_match_promotes_provisional_to_verified
    uid, rec, = caught(@a, status: "match")
    det.sweep
    assert_equal "verified", mon(uid)[:verify_state]
    assert_equal "verified", rec_action(rec)
    assert_equal 1, @db[:enforcement_events].where(account_id: @a, kind: "verify").count
  end

  # --- condemn: needs MIN_STRIKES distinct refuted battles ---------------------
  def test_single_walk_mismatch_under_strikes_does_not_quarantine
    uid, rec, = caught(@a, status: "walk_mismatch")
    det(strikes: 2).sweep
    assert_equal "active", mon(uid)[:status]        # 1 strike < 2 -> held, not quarantined
    assert_nil rec_action(rec)                      # left pending, revisited next sweep
  end

  def test_second_strike_quarantines_both_mons
    u1, r1, = caught(@a, status: "walk_mismatch")
    u2, r2, = caught(@a, status: "walk_mismatch")   # 2nd distinct refuted battle
    c = det(strikes: 2).sweep
    assert_equal 2, c[:quarantined]
    assert_equal "quarantined", mon(u1)[:status]
    assert_equal "quarantined", mon(u2)[:status]
    assert_equal "walk_mismatch", mon(u1)[:quarantine_reason]
    assert_equal "quarantined", rec_action(r1)
    assert_equal 2, @db[:enforcement_events].where(account_id: @a, kind: "quarantine").count
  end

  def test_condemn_poisons_the_roll_for_a_not_yet_minted_catch
    _, _, roll = caught(@a, status: "walk_mismatch")
    caught(@a, status: "walk_mismatch")             # 2nd strike arms the account
    det(strikes: 2).sweep
    refute_nil @db[:encounter_rolls].where(id: roll).get(:condemned_at)   # future claim births quarantined
  end

  # --- replay mismatch NEVER auto-condemns (drift-prone) -----------------------
  def test_replay_mismatch_is_not_condemned
    uid, rec, = caught(@a, status: "mismatch")      # harness replay verdict, not walk
    det(strikes: 1).sweep
    assert_equal "active", mon(uid)[:status]        # withheld from verified, never quarantined
    assert_nil rec_action(rec)
    assert_equal 0, @db[:enforcement_events].where(kind: "quarantine").count
  end

  # --- FP-storm breaker: a whole cohort failing = suppress ---------------------
  def test_fp_storm_across_accounts_suppresses_quarantine
    # 3 distinct accounts, same engine_fp, each with 2 strikes -> storm -> suppress
    c = acct("rv-c@x.co")
    [@a, @b, c].each do |acc|
      2.times { caught(acc, status: "walk_mismatch", fp: "deadbeef" * 4) }
    end
    counts = det(strikes: 2).sweep
    assert_operator counts[:suppressed], :>, 0
    assert_equal 0, counts[:quarantined]
    assert_equal 0, @db[:monsters].where(status: "quarantined").count
    assert_operator @db[:enforcement_events].where(kind: "suppression").count, :>, 0
  end

  # --- shadow audits, changes no state -----------------------------------------
  def test_shadow_would_quarantine_without_touching_state
    u1, r1, = caught(@a, status: "walk_mismatch")
    caught(@a, status: "walk_mismatch")
    c = det(mode: :shadow, strikes: 2).sweep
    assert_operator c[:would], :>, 0
    assert_equal "active", mon(u1)[:status]                 # NO state change
    assert_equal "would_quarantine", rec_action(r1)         # audited + stamped
    assert_operator @db[:enforcement_events].where(kind: "would_quarantine").count, :>, 0
  end

  def test_shadow_does_not_promote_verified
    uid, = caught(@a, status: "match")
    det(mode: :shadow).sweep
    assert_equal "provisional", mon(uid)[:verify_state]     # verify is a state change -> on only
  end

  # --- idempotency: a second sweep does nothing new ----------------------------
  def test_sweep_is_idempotent
    caught(@a, status: "walk_mismatch"); caught(@a, status: "walk_mismatch")
    det(strikes: 2).sweep
    before = @db[:enforcement_events].count
    det(strikes: 2).sweep
    assert_equal before, @db[:enforcement_events].count     # enforced_at gate -> no re-processing
  end
end

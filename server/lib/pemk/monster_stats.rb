# frozen_string_literal: true

module PEMK
  # M4 Layer D D6 part 1: the server's per-UID EXP HIGH-WATER — the beginning of per-mon
  # EXP authority. observe() records the most EXP each owned mon has legitimately reported
  # and flags a ROLLBACK when the client reports LESS (EXP never decreases in normal play,
  # so a decrease is an old save reloaded or an edited blob). Detection-only in part 1; the
  # same store is what part-2 `on` will reconcile the client's party against.
  #
  # THREADING: called only from the owning account's PlayerMailbox job, so the read-then-
  # write on a uid (which is globally unique and owned by exactly one account) has no
  # concurrent writer — no locks needed.
  class MonsterStats
    # Absolute EXP sanity ceiling when the species/curve is unknown (no battle_data
    # export, unknown species): comfortably above every vanilla growth rate's level-100
    # EXP (Fluctuating tops out at 1,640,000). A projected EXP above the cap is stored
    # CLAMPED — the high-water must never memorize (part 1) nor re-impose (part 2's
    # restore) an impossible value a hacked client once reported.
    FALLBACK_EXP_CAP = 2_000_000

    def initialize(db, battle: nil)
      @db     = db
      @battle = battle   # BattleData (optional) -> per-species growth-curve caps
    end

    # entries: [{uid:, exp:, level:}, ...] from the party projection. Only uids this
    # account actually OWNS are tracked (a client can't move another mon's high-water).
    # -> [{uid:, from:, to:}, ...] rollbacks detected (empty = clean).
    #
    # A rollback is reported ONCE per high-water via the rollback_flagged LATCH, NOT on
    # every frame while below it: a single no-fault crash (a restored save behind the live
    # high-water) re-projects the low EXP on login + every subsequent map/battle frame, and
    # un-latched that would blow past the D5 threshold with a dozen flags from one honest
    # event. The latch clears the moment EXP climbs back to/above the high-water, so a
    # genuinely NEW rollback later re-reports.
    def observe(account_id, entries, now: Time.now)
      # keep the first well-formed entry per uid (a party can't legitimately list a uid twice)
      by_uid = {}
      entries.each do |e|
        u = e[:uid]
        next unless u.is_a?(Integer) && e[:exp].is_a?(Integer) && e[:exp] >= 0
        by_uid[u] ||= e
      end
      return [] if by_uid.empty?

      owned = owned_uids(account_id, by_uid.keys)
      return [] if owned.empty?

      stats = @db[:monster_stats].where(uid: owned).to_hash(:uid)   # {uid => row}, one query
      rollbacks = []
      owned.each do |uid|
        e = by_uid[uid]; level = int_or(e[:level], 0)
        exp = [e[:exp], exp_cap(e[:species])].min   # sanity-clamp: never memorize the impossible
        row = stats[uid]
        if row.nil?
          insert_row(uid, exp, level, now)
        elsif exp >= row[:exp]
          # legit growth (or a re-report at the high-water): raise it, clear the latch
          update_row(uid, exp: exp, level: level, rollback_flagged: false, now: now)
        elsif !row[:rollback_flagged]
          # first time below THIS high-water — report once and latch (high-water untouched)
          rollbacks << { uid: uid, from: row[:exp], to: exp }
          update_row(uid, rollback_flagged: true, now: now)
        end
        # else: below the high-water but already latched -> suppress (no re-flag)
      end
      rollbacks
    end

    # The server's high-water for a uid (nil if untracked) — for part-2 reconcile + tests.
    def exp_for(uid)
      @db[:monster_stats].where(uid: uid).get(:exp)
    end

    # D6 part 2 (`on`): the UP-ONLY restore plan. For each OWNED uid whose stored
    # high-water exceeds the reported exp -> {uid:, exp: high_water, level: stored_level}.
    # Read-only (observe() owns the latch + writes) and bounded by the party projection
    # (<=6 entries). :level is SERVER-INTERNAL (the level recorded at the high-water) —
    # the caller strips it from the wire and uses it to exempt the restore's own level
    # jump from the D4 reward audit. The caller re-emits this every below-frame — the
    # client's own up-only guard makes a re-send a no-op, and once the restore lands the
    # next projection reports AT the high-water and the plan goes empty (self-terminating).
    def corrections(account_id, entries)
      by_uid = {}
      entries.each do |e|
        u = e[:uid]
        next unless u.is_a?(Integer) && e[:exp].is_a?(Integer) && e[:exp] >= 0
        by_uid[u] ||= e
      end
      return [] if by_uid.empty?

      owned = owned_uids(account_id, by_uid.keys)
      return [] if owned.empty?

      stats = @db[:monster_stats].where(uid: owned).to_hash(:uid)
      out = []
      owned.each do |uid|
        row = stats[uid]
        next unless row

        hw = [row[:exp], exp_cap(by_uid[uid][:species])].min   # belt: never EMIT the impossible either
        out << { uid: uid, exp: hw, level: row[:level] } if hw > by_uid[uid][:exp]
      end
      out
    end

    private

    def owned_uids(account_id, uids)
      @db[:monsters].where(id: uids.uniq, owner_account_id: account_id).select_map(:id)   # <=6, array is fine
    end

    def insert_row(uid, exp, level, now)
      @db[:monster_stats].insert(uid: uid, exp: exp, level: int_or(level, 0),
                                 rollback_flagged: false, first_at: now, updated_at: now)
    rescue Sequel::UniqueConstraintViolation
      # raced with another insert for the same uid (shouldn't happen under the mailbox) —
      # fall back to a high-water update.
      update_row(uid, exp: exp, level: int_or(level, 0), rollback_flagged: false, now: now)
    end

    # partial update: only the passed columns move; +now+ always stamps updated_at.
    def update_row(uid, now:, **cols)
      @db[:monster_stats].where(uid: uid).update(cols.merge(updated_at: now))
    end

    def int_or(v, default)
      v.is_a?(Integer) ? v : default
    end

    # The most EXP +species+ can legitimately hold: its growth curve's level-cap value
    # (battle_data export), else the global fallback (no export / unknown species).
    def exp_cap(species)
      if @battle
        sp   = @battle.species(species.to_s)
        rate = sp && sp["growth_rate"]
        cap  = rate && @battle.growth_rate_max_exp(rate)
        return cap if cap.is_a?(Integer) && cap.positive?
      end
      FALLBACK_EXP_CAP
    end
  end
end

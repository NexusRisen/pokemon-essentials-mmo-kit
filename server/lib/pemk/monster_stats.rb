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
    def initialize(db)
      @db = db
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
        e = by_uid[uid]; exp = e[:exp]; level = int_or(e[:level], 0)
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
  end
end

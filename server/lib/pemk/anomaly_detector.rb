# frozen_string_literal: true

module PEMK
  # M4 Layer D D5: statistical anomaly detection — the cross-battle BACKSTOP for the
  # residuals D2-D4 admit (HP-shaded catches, under-the-bound EXP, fabricated wild mons).
  # Purely server-side: it aggregates telemetry the earlier layers already produce into a
  # per-account risk picture and writes a human REVIEW QUEUE. It NEVER auto-enforces — a
  # lucky player looks like a cheat, so every signal is advisory.
  #
  # Two signals in this first cut:
  #   1. player_flags — discrete SUSPECT events (record_flag, atomic upsert) accumulated
  #      per account; a kind crossing its threshold is reported.
  #   2. provenance mix — a "client"-origin mon whose species EXISTS in a wild encounter
  #      table is a fabricated wild catch (D3.2 labels the honest one "wild_caught"); at
  #      volume, and outnumbering the account's real wild_caught, it is reported.
  #
  # THREADING: record_flag and sweep both use the Sequel connection pool (thread-safe)
  # and are called only from worker threads (never the reactor thread) — record_flag is
  # an atomic INSERT..ON CONFLICT, sweep is read-mostly + idempotent upserts, so no locks.
  class AnomalyDetector
    # A kind's count at/over its threshold opens a review report. Tuned generously
    # (detection, not punishment) — these are per-discrete-event, not per-resend.
    FLAG_THRESHOLDS = {
      "reward_money"        => 8,    # money deltas beyond a battle's yield
      "reward_level"        => 4,    # impossible party level jumps
      "catch_spam"          => 3,    # 21+ throws brute-forcing one mint
      "encounter_species"   => 5,    # locally-rolled a species not in the map table
      "encounter_wrong_map" => 8     # claimed an encounter on a map they're not on
    }.freeze

    FABRICATED_WILD_MIN = 5   # >= this many client-origin wild-table mons to report

    def initialize(db, world, logger: nil)
      @db    = db
      @world = world
      @log   = logger || ->(_m) {}
    end

    # Atomically bump an account's counter for a discrete SUSPECT event. Fire-and-forget.
    def record_flag(account_id, kind, now: Time.now)
      k = kind.to_s
      @db[:player_flags]
        .insert_conflict(target: %i[account_id kind],
                         update: { count: Sequel[:player_flags][:count] + 1, last_at: now })
        .insert(account_id: account_id, kind: k, count: 1, first_at: now, last_at: now)
    rescue StandardError => e
      @log.call("anomaly: record_flag(#{kind}) failed #{e.class}: #{e.message}")
    end

    # The periodic aggregation: recompute both signals and refresh the review queue.
    # -> number of reports written/updated. Runs on a worker thread.
    def sweep(now: Time.now)
      n = sweep_flags(now) + sweep_provenance(now)
      @log.call("anomaly: sweep refreshed #{n} report(s)") if n.positive?
      n
    rescue StandardError => e
      @log.call("anomaly: sweep failed #{e.class}: #{e.message}")
      0
    end

    # Open (unreviewed) reports, newest first — for an operator / admin surface.
    def open_reports(limit: 100)
      @db[:anomaly_reports].where(reviewed_at: nil).order(Sequel.desc(:updated_at)).limit(limit).all
    end

    private

    def sweep_flags(now)
      count = 0
      @db[:player_flags].each do |row|
        thr = FLAG_THRESHOLDS[row[:kind]]
        next unless thr && row[:count] >= thr

        upsert_report(row[:account_id], "flags:#{row[:kind]}", row[:count],
                      "#{row[:count]} #{row[:kind]} events (>= #{thr})", now)
        count += 1
      end
      count
    end

    def sweep_provenance(now)
      wild = @world.wild_species
      return 0 if wild.empty?

      # Let Postgres do the counting, grouped by the MINTER (issuer_account_id) — origin is
      # immutable across a trade while owner_account_id moves, so grouping by owner would
      # frame an innocent recipient of a fabricated mon (and let an attacker grief a victim's
      # queue). Eggs are excluded (gift/hatched eggs of wild species are legitimately
      # client-minted). origin is NULL for legacy / non-on-mode mints -> neither bucket.
      client_wild = counts_by_issuer(@db[:monsters].where(origin: "client", egg_at_issue: false, species: wild))
      wild_caught = counts_by_issuer(@db[:monsters].where(origin: "wild_caught"))

      count = 0
      client_wild.each do |account_id, cw|
        next unless cw >= FABRICATED_WILD_MIN && cw > wild_caught.fetch(account_id, 0)

        upsert_report(account_id, "fabricated_wild", cw,
                      "#{cw} client-origin wild-table mons vs #{wild_caught.fetch(account_id, 0)} wild_caught", now)
        count += 1
      end
      count
    end

    def counts_by_issuer(ds)
      out = {}
      ds.group_and_count(:issuer_account_id).each { |r| out[r[:issuer_account_id]] = r[:count] }
      out
    end

    # Idempotent: refresh score/detail/updated_at, keep created_at and an operator's
    # reviewed_at (a reviewed account isn't re-alerted for the same kind).
    def upsert_report(account_id, kind, score, detail, now)
      @db[:anomaly_reports]
        .insert_conflict(target: %i[account_id kind],
                         update: { score: score, detail: detail, updated_at: now })
        .insert(account_id: account_id, kind: kind, score: score, detail: detail,
                created_at: now, updated_at: now)
    end
  end
end

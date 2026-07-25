# frozen_string_literal: true

module PEMK
  # Audit item 4: the server's DETECTION shadow of RPG-Maker switches, variables and
  # self-switches — the state the north star says the server must own and which, until
  # now, it could not even observe.
  #
  # The client pushes the WHOLE non-default set as an absolute snapshot (the `:inv`
  # pattern: reconnect-safe, self-healing, last_seq high-water dedup). We RECORD it and
  # flag a REWIND, but never reject: the save blob stays authoritative until the
  # world-vs-player ID partition is decided (a game-design call, not an engineering one).
  #
  # WHAT COUNTS AS A REWIND — calibrated to avoid punishing honest play:
  #   * self-switches that were ON and are now OFF => THE signal. A self-switch is the
  #     engine's "this one-shot event has happened" marker; vanilla event scripts set
  #     them and effectively never clear them, so a batch of them going OFF is a save
  #     rollback, and it is exactly what re-farms NPC gifts / TMs / key items.
  #   * switches going OFF and variables DECREASING are RECORDED but NOT flagged:
  #     both legitimately happen all the time (temp flags, countdowns, counters reset
  #     by events), so judging them would flood the queue with honest players.
  # A single self-switch clearing is tolerated (some games do reset one deliberately);
  # REWIND_MIN of them in one step is the reportable event.
  class FlagState
    REWIND_MIN   = 3       # self-switches cleared in one snapshot before it is reportable
    MAX_ENTRIES  = 4_000   # per section; beyond it the snapshot is recorded but NOT judged

    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # payload: { switches: [id,...], variables: {id=>int}, self_switches: ["m:e:A",...] }
    # -> [:ack, flags] | [:dup, []] | [:rej, ["bad_shape"]]
    def apply_flags(account_id, payload, seq, now: Time.now)
      return [:rej, ["bad_shape"]] unless payload.is_a?(Hash) && seq.is_a?(Integer)

      switches = int_list(payload[:switches])
      selfsw   = str_list(payload[:self_switches])
      vars     = var_map(payload[:variables])
      return [:rej, ["bad_shape"]] if switches.nil? || selfsw.nil? || vars.nil?

      truncated = switches.length > MAX_ENTRIES || selfsw.length > MAX_ENTRIES ||
                  vars.size > MAX_ENTRIES

      result = nil
      @db.transaction do
        row = @db[:flag_snapshots].where(account_id: account_id).first
        if row && seq <= row[:last_seq]
          result = [:dup, []]   # replayed/stale absolute snapshot -> re-ack, no write
        else
          flags = truncated ? ["truncated"] : detect_rewind(account_id, row, switches, selfsw, vars)
          store(account_id, switches, vars, selfsw, seq, truncated, flags, now)
          result = [:ack, flags]
        end
      end
      result
    rescue StandardError => e
      @log.call("flags: apply failed #{e.class}: #{e.message}")
      [:rej, ["error"]]
    end

    def snapshot(account_id)
      @db[:flag_snapshots].where(account_id: account_id).first
    end

    private

    # -> flags (["rewind"] when the self-switch drop is reportable). Switch/variable
    # regressions are logged for the operator but never flagged (see the header).
    def detect_rewind(account_id, row, switches, selfsw, vars)
      return [] unless row
      # A comparison against a TRUNCATED baseline is meaningless: entries the previous
      # snapshot had to drop would read as cleared. Record, don't judge, until a full
      # snapshot re-establishes the baseline.
      return ["truncated"] if row[:truncated]

      prev_self = Array(row[:self_switches].to_a)
      cleared   = prev_self - selfsw
      prev_sw   = Array(row[:switches].to_a)
      sw_off    = prev_sw - switches
      prev_vars = row[:variables].to_h
      dropped   = prev_vars.count { |k, v| v.is_a?(Integer) && vars[k.to_s].is_a?(Integer) && vars[k.to_s] < v }

      if sw_off.any? || dropped.positive?
        @log.call("flags: account #{account_id} regression — #{sw_off.length} switch(es) off, " \
                  "#{dropped} variable(s) decreased (recorded, not judged)")
      end
      return [] if cleared.length < REWIND_MIN

      @log.call("flags: account #{account_id} SUSPECT rewind — #{cleared.length} self-switches cleared " \
                "(#{cleared.first(5).join(', ')}#{cleared.length > 5 ? ', …' : ''}) — one-shot events re-armed")
      ["rewind"]
    end

    def store(account_id, switches, vars, selfsw, seq, truncated, flags, now)
      @db[:flag_snapshots]
        .insert_conflict(target: :account_id,
                         update: { switches: Sequel.pg_jsonb(switches), variables: Sequel.pg_jsonb(vars),
                                   self_switches: Sequel.pg_jsonb(selfsw), last_seq: seq,
                                   truncated: truncated, flagged: flags.any?,
                                   flags: Sequel.pg_jsonb(flags), updated_at: now })
        .insert(account_id: account_id, switches: Sequel.pg_jsonb(switches),
                variables: Sequel.pg_jsonb(vars), self_switches: Sequel.pg_jsonb(selfsw),
                last_seq: seq, truncated: truncated, flagged: flags.any?,
                flags: Sequel.pg_jsonb(flags), updated_at: now)
    end

    # --- shape guards (hostile input) -----------------------------------------

    def int_list(v)
      return [] if v.nil?
      return nil unless v.is_a?(Array) && v.all? { |i| i.is_a?(Integer) && i.between?(0, 5000) }

      v.uniq.sort
    end

    def str_list(v)
      return [] if v.nil?
      return nil unless v.is_a?(Array) && v.all? { |s| s.is_a?(String) && s.length <= 32 }

      v.uniq.sort
    end

    def var_map(v)
      return {} if v.nil?
      return nil unless v.is_a?(Hash)

      out = {}
      v.each do |k, val|
        id = k.to_s
        return nil unless id.match?(/\A\d{1,4}\z/) && id.to_i.between?(0, 5000)
        next unless val.is_a?(Integer)   # non-Integer values are not judged, just dropped

        out[id] = val
      end
      out
    end
  end
end

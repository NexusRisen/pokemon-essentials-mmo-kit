# frozen_string_literal: true

require "set"

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

    # policy: { switches: Set/Array of non-local ids, variables: ... }. The comparison
    # is only meaningful over ids the POLICY claims — a LOCAL id is legitimately absent
    # from the delta stream, and judging it would report our own scope as a divergence.
    def initialize(db, policy: nil, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
      @owned_switches = to_id_set(policy && (policy[:switches] || policy["switches"]))
      @owned_vars     = to_id_set(policy && (policy[:variables] || policy["variables"]))
    end

    def to_id_set(list)
      return nil unless list   # nil = no policy = compare nothing (inert)

      list.map(&:to_i).to_set
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
          # THE TRUST GATE measurement: does the delta-built mirror agree with the
          # absolute truth? Reported, never enforced — a disagreement is evidence
          # about OUR interception, not about the player.
          drift = compare_mirror(account_id, row, switches, selfsw, vars)
          unless drift.empty?
            @log.call("flags: account #{account_id} DELTA DRIFT — #{drift.join('; ')}")
          end
          store(account_id, switches, vars, selfsw, seq, truncated, flags, now, drift)
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

    # --- step 3: the delta stream + THE TRUST GATE -----------------------------
    #
    # The client sends every intercepted write as a delta. We apply it to our own
    # copy of the state; when the next ABSOLUTE snapshot arrives we compare the two.
    # If they agree across real play, the interception is complete and the server may
    # eventually own this state. If they disagree, the stream is lossy and NOTHING
    # further may be built on it — which is the entire point of shipping this in
    # shadow first. Divergence is reported, never enforced.
    #
    # -> [:ok, drift] | [:bad, []] — drift is a human-readable list of disagreements.
    def apply_delta(account_id, payload, now: Time.now)
      return [:bad, []] unless payload.is_a?(Hash)

      sw   = bool_map(payload[:switches])
      selfsw = bool_map(payload[:self_switches])
      vars = payload[:variables].is_a?(Hash) ? payload[:variables] : {}
      return [:bad, []] if sw.nil? || selfsw.nil?

      @db.transaction do
        row = @db[:flag_snapshots].where(account_id: account_id).first
        return [:bad, []] unless row

        # Apply onto the mirror we keep beside the snapshot. An overflowed delta
        # invalidates the mirror (we know it is incomplete), so we stop comparing
        # until the next absolute snapshot re-establishes it.
        mirror = row[:mirror].respond_to?(:to_h) ? row[:mirror].to_h : seed_mirror(row)
        if payload[:overflow] == true
          @db[:flag_snapshots].where(account_id: account_id)
                              .update(mirror_valid: false, updated_at: now)
          return [:ok, []]
        end

        sw.each     { |id, on| apply_set(mirror, "sw", id, on) }
        selfsw.each { |k, on|  apply_set(mirror, "ss", k, on) }
        vars.each   { |id, v|  mirror["var/#{id}"] = v if v.is_a?(Integer) }

        @db[:flag_snapshots].where(account_id: account_id)
                            .update(mirror: Sequel.pg_jsonb(mirror), updated_at: now)
      end
      [:ok, []]
    rescue StandardError => e
      @log.call("flags: delta failed #{e.class}: #{e.message}")
      [:bad, []]
    end

    # Called when an absolute snapshot lands: does the delta-built mirror agree?
    # This IS the trust gate's measurement.
    def compare_mirror(account_id, row, switches, selfsw, vars)
      # NOTE: Sequel hands jsonb back as a DelegateClass(Hash), NOT a Hash subclass —
      # an `is_a?(Hash)` guard here silently disabled the whole gate. Use to_h, as the
      # rest of this file already does for :variables / :switches.
      return [] unless row && row[:mirror_valid] && row[:mirror].respond_to?(:to_h)

      return [] unless @owned_switches   # no policy -> nothing is ours -> nothing to judge

      mirror = row[:mirror].to_h
      drift  = []

      # SWITCHES — compared over the policy-owned ids ONLY. A local id is absent from
      # the delta stream by design; an OWNED id present in the truth but missing from
      # the mirror is exactly the missed write this gate exists to catch.
      want = switches.select { |i| @owned_switches.include?(i) }.map { |i| "sw/#{i}" }
      have = mirror.keys.select { |k| k.start_with?("sw/") && mirror[k] &&
                                      @owned_switches.include?(k.split("/", 2)[1].to_i) }
      missing = want - have
      extra   = have - want
      unless missing.empty? && extra.empty?
        drift << "switches missed=#{missing.first(3).join(',')} stale=#{extra.first(3).join(',')}"
      end

      # SELF-SWITCHES — the whole namespace is owned (they are one-shot markers).
      want_ss = selfsw.map { |k| "ss/#{k}" }
      have_ss = mirror.keys.select { |k| k.start_with?("ss/") && mirror[k] }
      ss_missing = want_ss - have_ss
      ss_extra   = have_ss - want_ss
      unless ss_missing.empty? && ss_extra.empty?
        drift << "self_switches missed=#{ss_missing.first(3).join(',')} stale=#{ss_extra.first(3).join(',')}"
      end

      vars.each do |id, v|
        next unless @owned_vars&.include?(id.to_i)

        m = mirror["var/#{id}"]
        next if m == v

        drift << "var #{id} mirror=#{m.inspect} snapshot=#{v}"
      end
      drift.first(8)
    end

    def apply_set(mirror, prefix, key, on)
      k = "#{prefix}/#{key}"
      mirror[k] = on ? true : false
    end

    # An absolute snapshot IS the truth, so it always re-establishes the mirror.
    def mirror_from(switches, vars, selfsw)
      m = {}
      switches.each { |i| m["sw/#{i}"] = true }
      selfsw.each   { |k| m["ss/#{k}"] = true }
      vars.each     { |id, v| m["var/#{id}"] = v }
      m
    end

    def seed_mirror(row)
      m = {}
      Array(row[:switches].to_a).each { |i| m["sw/#{i}"] = true }
      Array(row[:self_switches].to_a).each { |k| m["ss/#{k}"] = true }
      row[:variables].to_h.each { |id, v| m["var/#{id}"] = v }
      m
    end

    def bool_map(h)
      return {} if h.nil?
      return nil unless h.is_a?(Hash)

      out = {}
      h.each { |k, v| out[k.to_s] = (v == true) }
      out
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

    def store(account_id, switches, vars, selfsw, seq, truncated, flags, now, drift = [])
      @db[:flag_snapshots]
        .insert_conflict(target: :account_id,
                         update: { switches: Sequel.pg_jsonb(switches), variables: Sequel.pg_jsonb(vars),
                                   self_switches: Sequel.pg_jsonb(selfsw), last_seq: seq,
                                   truncated: truncated, flagged: flags.any?,
                                   flags: Sequel.pg_jsonb(flags), updated_at: now,
                                   mirror: Sequel.pg_jsonb(mirror_from(switches, vars, selfsw)),
                                   mirror_valid: true,
                                   drift_at: (drift.empty? ? nil : now),
                                   drift: (drift.empty? ? nil : drift.join('; ')[0, 500]) })
        .insert(account_id: account_id, switches: Sequel.pg_jsonb(switches),
                variables: Sequel.pg_jsonb(vars), self_switches: Sequel.pg_jsonb(selfsw),
                last_seq: seq, truncated: truncated, flagged: flags.any?,
                flags: Sequel.pg_jsonb(flags), updated_at: now,
                mirror: Sequel.pg_jsonb(mirror_from(switches, vars, selfsw)), mirror_valid: true,
                drift_at: (drift.empty? ? nil : now), drift: (drift.empty? ? nil : drift.join('; ')[0, 500]))
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

# frozen_string_literal: true

module PEMK
  # Audit item 5: the server-owned per-mon STAT BLOCK — a FIRST-SIGHT LOCK on the traits
  # the game's own rules never change, so a counterfeit mon carrying a valid uid stops
  # being invisible. This is the prerequisite ranked PvP (D9) actually needs: today a
  # ladder would rank client-self-reported teams that no server row contradicts.
  #
  # WHAT IS LOCKED (and why it is safe to judge):
  #   * IVs — set at creation; the ONLY legal change is Hyper Training, which raises a
  #     stat TO 31. So a decrease, or an increase to anything other than 31, is an edit.
  #   * shiny / gender — derived from the personalID at creation, fixed for life.
  # WHAT IS RECORDED BUT NEVER JUDGED (all legitimately change in normal play):
  #   level, EXP, EVs (berries reduce them), moves, ability (Ability Capsule/Patch),
  #   held item, nature (Mints), species and form (evolution, Rotom, Deoxys...).
  #
  # Runs under the owning account's PlayerMailbox, and only for uids the account OWNS —
  # a client can never write or divert another player's block.
  class MonsterBlocks
    STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze
    IV_MAX = 31

    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # entries: [{uid:, species:, level:, ivs:, evs:, moves:, ability:, nature:, item:,
    #            shiny:, gender:}, ...] — the D1 team frame, now uid-bound.
    # -> [{uid:, reasons: [...]}, ...] divergences (empty = clean).
    def observe(account_id, entries, now: Time.now)
      by_uid = {}
      Array(entries).each do |e|
        next unless e.is_a?(Hash) && e[:uid].is_a?(Integer)

        by_uid[e[:uid]] ||= e
      end
      return [] if by_uid.empty?

      owned = owned_uids(account_id, by_uid.keys)
      return [] if owned.empty?

      rows = @db[:monster_blocks].where(uid: owned).to_hash(:uid)
      diverged = []
      owned.each do |uid|
        e   = by_uid[uid]
        row = rows[uid]
        if row.nil?
          insert_block(uid, e, now)   # first sight: the lock is established
          next
        end

        reasons = compare(row, e)
        update_block(uid, e, reasons, now)
        next if reasons.empty?

        @log.call("block: account #{account_id} SUSPECT uid#{uid} — #{reasons.join(', ')}")
        diverged << { uid: uid, reasons: reasons }
      end
      diverged
    rescue StandardError => e
      @log.call("block: observe failed #{e.class}: #{e.message}")
      []
    end

    def block_for(uid)
      @db[:monster_blocks].where(uid: uid).first
    end

    private

    # Only the LOCKED traits are judged — see the header for why each is safe.
    def compare(row, e)
      reasons = []
      prev = row[:ivs].to_h
      now_ivs = iv_hash(e[:ivs])
      if now_ivs
        STATS.each do |s|
          was = prev[s]
          isv = now_ivs[s]
          next unless was.is_a?(Integer) && isv.is_a?(Integer) && was != isv
          # Hyper Training is the one legal change, and it can only set a stat TO 31.
          next if isv == IV_MAX && isv > was

          reasons << "iv_#{s.downcase}:#{was}->#{isv}"
        end
      end
      reasons << "shiny:#{row[:shiny]}->#{e[:shiny] == true}" if e.key?(:shiny) && !e[:shiny].nil? &&
                                                                (e[:shiny] == true) != row[:shiny]
      if e[:gender].is_a?(Integer) && row[:gender].is_a?(Integer) && e[:gender] != row[:gender]
        reasons << "gender:#{row[:gender]}->#{e[:gender]}"
      end
      reasons
    end

    def insert_block(uid, e, now)
      @db[:monster_blocks].insert(
        uid: uid, species: e[:species].to_s, level: int_or(e[:level], 0),
        ivs: Sequel.pg_jsonb(iv_hash(e[:ivs]) || {}), evs: Sequel.pg_jsonb(iv_hash(e[:evs]) || {}),
        moves: Sequel.pg_jsonb(Array(e[:moves]).map(&:to_s)),
        ability: str_or_nil(e[:ability]), nature: str_or_nil(e[:nature]), item: str_or_nil(e[:item]),
        shiny: e[:shiny] == true, gender: (e[:gender] if e[:gender].is_a?(Integer)),
        diverged: false, first_at: now, updated_at: now
      )
    rescue Sequel::UniqueConstraintViolation
      nil   # raced with itself under the mailbox — the row exists, nothing to do
    end

    # The mutable traits are refreshed so the block tracks the mon; the LOCKED ones are
    # deliberately NOT overwritten, or a counterfeit would launder itself on the next
    # report by simply repeating its lie.
    def update_block(uid, e, reasons, now)
      cols = { species: e[:species].to_s, level: int_or(e[:level], 0),
               evs: Sequel.pg_jsonb(iv_hash(e[:evs]) || {}),
               moves: Sequel.pg_jsonb(Array(e[:moves]).map(&:to_s)),
               ability: str_or_nil(e[:ability]), nature: str_or_nil(e[:nature]),
               item: str_or_nil(e[:item]), updated_at: now }
      if reasons.any?
        cols[:diverged] = true
        cols[:flags] = Sequel.lit("flags || ?::jsonb",
                                  [{ "at" => now.utc.iso8601, "reasons" => reasons }].to_json)
      end
      @db[:monster_blocks].where(uid: uid).update(cols)
    end

    def owned_uids(account_id, uids)
      @db[:monsters].where(id: uids.uniq, owner_account_id: account_id).select_map(:id)
    end

    def iv_hash(h)
      return nil unless h.is_a?(Hash)

      out = {}
      STATS.each do |s|
        v = h[s] || h[s.to_sym]
        out[s] = v if v.is_a?(Integer) && v.between?(0, 255)
      end
      out
    end

    def str_or_nil(v)
      s = v.to_s
      s.empty? || s.length > 64 ? nil : s
    end

    def int_or(v, default)
      v.is_a?(Integer) ? v : default
    end
  end
end

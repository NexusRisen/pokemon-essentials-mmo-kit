# frozen_string_literal: true

# Milestone 4 Layer D D5 — statistical anomaly detection (the cross-battle backstop).
# Two additive tables (open-source servers just migrate):
#
# player_flags — per-account rolling counters of discrete SUSPECT events the D2-D4
# checks already detect (an over-budget money delta, an impossible level jump, catch
# spam, a fabricated encounter). One row per (account, kind), incremented atomically.
#
# anomaly_reports — the human REVIEW QUEUE. The periodic sweep writes/updates one row
# per (account, kind) when a signal crosses its threshold (accumulated flags, or a
# provenance mix of client-fabricated wild-table mons). D5 NEVER auto-enforces — a
# report is a flag for a human, because lucky players can look like cheats. reviewed_at
# is set by an operator; cascade on account delete.
Sequel.migration do
  change do
    create_table(:player_flags) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :kind,  null: false
      Integer  :count, null: false, default: 0
      DateTime :first_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :last_at,  null: false, default: Sequel::CURRENT_TIMESTAMP

      primary_key %i[account_id kind], name: :player_flags_pk
    end

    create_table(:anomaly_reports) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :kind,   null: false
      Integer  :score,  null: false
      String   :detail, null: false, text: true
      DateTime :created_at,  null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at,  null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :reviewed_at, null: true

      index %i[account_id kind], unique: true, name: :anomaly_reports_dedup
    end

    # Speeds the D5 provenance sweep (group minted origins by issuer); partial so it stays
    # tiny — only mints that carry a provenance label (NULL = legacy / non-on-mode).
    alter_table(:monsters) do
      add_index :issuer_account_id, name: :monsters_origin_issuer, where: Sequel.lit("origin IS NOT NULL")
    end
  end
end

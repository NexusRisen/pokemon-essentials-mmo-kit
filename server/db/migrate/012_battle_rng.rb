# frozen_string_literal: true

# Milestone 4 Layer D D7 part 1 — the deterministic battle seam's server side.
#
# encounter_rolls.battle_seed (additive, NULL = rng off / pre-D7 rolls): the 63-bit
# PCG32 seed minted WITH the encounter roll when PEMK_BATTLE_ENFORCE_RNG is active.
# 63-bit on purpose: Postgres bigint is SIGNED — a full 64-bit seed would raise on
# ~half of inserts. The seed is born bound to the mint (it rides :encounter_grant),
# and its single-use is a DB constraint here, not client honor: battle_records may
# reference a roll at most once (partial unique index below).
#
# battle_records: the D7 parity CORPUS — one row per client-captured wild battle
# (shadow: vanilla RNG, drawn values captured; on: PCG32 streams, values derived from
# the seed). The raw primitive-encoded record body is stored VERBATIM (bytea) for the
# part-2 headless replay; the promoted columns are triage metadata. u64 stream
# fingerprints are stored as HEX TEXT (the signed-bigint trap again). replay_status
# is part 2/3's workflow column (pending -> match | mismatch | error).
Sequel.migration do
  change do
    alter_table(:encounter_rolls) do
      add_column :battle_seed, :Bignum, null: true
    end

    create_table(:battle_records) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      foreign_key :encounter_roll_id, :encounter_rolls, type: :Bignum, null: true, on_delete: :set_null
      String   :mode,        null: false               # "shadow" | "on" (as armed client-side)
      Bignum   :battle_seed, null: true                # echo of the roll's seed (self-contained replay)
      String   :engine_fp,   null: true                # client engine fingerprint (cohort key)
      File     :record,      null: false               # raw primitive-encoded record body (bytea)
      Integer  :outcome,     null: true                # engine decision (1 won/2 lost/3 fled/4 caught/5 draw)
      Integer  :rounds,      null: true
      Integer  :draws_battle, null: true               # per-stream draw counts (desync localization)
      Integer  :draws_ai,     null: true
      Integer  :draws_run,    null: true
      String   :fp_battle,   null: true                # FNV-1a64 of drawn values, hex text (u64-safe)
      String   :fp_ai,       null: true
      String   :fp_run,      null: true
      String   :replay_status, null: false, default: "pending"
      DateTime :created_at,  null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[account_id created_at]
      index %i[replay_status]
      # single-use: one record per minted roll, enforced by the database
      index :encounter_roll_id, unique: true, name: :battle_records_roll_once,
            where: Sequel.~(encounter_roll_id: nil)
    end
  end
end

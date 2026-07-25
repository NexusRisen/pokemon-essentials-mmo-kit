# frozen_string_literal: true

# Milestone 4 Layer D D8 — per-battle re-sim ENFORCEMENT (additive, all inert until
# PEMK_BATTLE_ENFORCE_RESIM is raised; design: "provisional-until-verified, walk-tier
# bite" — only the ingest-time seed walk (cryptographic refutation) can auto-quarantine;
# harness replay verdicts certify or withhold, never condemn alone).
#
# monsters.verify_state: none (default; pre-D8 / unseeded) | provisional (born from a
#   SEEDED roll — a record is owed; trades hold until the walk clears it, fail-open TTL)
#   | verified (its battle record replayed to match — the D9 ranked-eligibility asset).
# monsters quarantine columns: status='quarantined' does the actual gating (the M3.2
#   trade CAS requires status='active' — zero trade-code change); these columns are the
#   evidence trail. Reversal is one UPDATE (operator pardon CLI).
# encounter_rolls.claimed_monster_uid: stamped inside the SAME claim UPDATE that sets
#   claimed_at — the roll->mon link enforcement walks (single-row crash story; the
#   mon->roll direction is derived by join, never duplicated).
# encounter_rolls.condemned_at: a walk-refuted roll is POISONED — if its catch has not
#   minted yet, the mon is born quarantined when the claim lands (no race).
# battle_records verdict/enforcement columns: verdict_at (when replay_status was last
#   stamped), enforcement_action + enforced_at (the sweep's idempotency + audit:
#   quarantined | suppressed_cohort | suppressed_breaker | would_quarantine | verified).
#   replay_status STATE MACHINE (documented here, enforced by convention): the HARNESS
#   may only transition pending|walk_ok -> match|mismatch|error|not_replayable; the
#   LIVE SERVER owns walk_* / no_log / mode_mismatch (ingest) and enforcement columns.
# enforcement_events: append-only audit of every enforcement decision (including
#   suppressions) — the operator's "why did/didn't this happen" answer.
Sequel.migration do
  change do
    alter_table(:monsters) do
      add_column :verify_state, String, null: false, default: "none"
      add_column :quarantined_at, DateTime, null: true
      add_column :quarantine_reason, String, null: true
      add_column :quarantine_record_id, :Bignum, null: true   # evidence battle_records.id (soft ref — records prune)
      add_index  :verify_state
    end

    alter_table(:encounter_rolls) do
      add_column :claimed_monster_uid, :Bignum, null: true
      add_column :condemned_at, DateTime, null: true
    end

    alter_table(:battle_records) do
      add_column :verdict_at, DateTime, null: true
      add_column :enforcement_action, String, null: true
      add_column :enforced_at, DateTime, null: true
    end

    create_table(:enforcement_events) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false   # NO cascade — audit survives account deletion
      String   :kind,        null: false            # quarantine | pardon | suppression | would_quarantine | verify
      Bignum   :monster_uid, null: true
      Bignum   :record_id,   null: true
      String   :detail,      null: true
      DateTime :created_at,  null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[account_id created_at]
    end
  end
end

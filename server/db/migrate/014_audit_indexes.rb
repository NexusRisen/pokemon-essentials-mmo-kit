# frozen_string_literal: true

# Audit follow-up (2026-07-25) — the indexes the shipped query predicates actually need.
# Purely additive: no column or table changes, no behavior change, safe on a populated DB.
#
# * encounter_rolls(battle_seed) — BattleRecords#ingest looks the roll up BY SEED on every
#   :battle_record; seeds are 63-bit random so the partial index is highly selective.
# * encounter_rolls(claimed_monster_uid) — Trades#held_provisional? runs this lookup INSIDE
#   the trade transaction, where a seq scan holds row locks longer than it should.
# * encounter_rolls(account_id, caught_at) WHERE battle_seed NOT NULL — the D5 rng_silent
#   and D8 claim-evasion sweeps scan seeded+caught rolls every 60s.
# * battle_records(account_id, created_at) already exists (012); add the enforcement-sweep
#   predicate (replay_status, enforcement_action) used by both ResimVerdicts passes.
Sequel.migration do
  change do
    alter_table(:encounter_rolls) do
      add_index :battle_seed, name: :encounter_rolls_seed, where: Sequel.~(battle_seed: nil)
      add_index :claimed_monster_uid, name: :encounter_rolls_claimed_mon,
                where: Sequel.~(claimed_monster_uid: nil)
      add_index %i[account_id caught_at], name: :encounter_rolls_seeded_caught,
                where: Sequel.~(battle_seed: nil)
    end

    alter_table(:battle_records) do
      add_index %i[replay_status enforcement_action], name: :battle_records_enforcement
    end
  end
end

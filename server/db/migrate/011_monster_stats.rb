# frozen_string_literal: true

# Milestone 4 Layer D D6 part 1 — per-mon EXP authority (foundation + rollback detection).
# The party is blob-authoritative today (party_snapshots stores it detection-only). This
# additive table gives the server a per-UID EXP HIGH-WATER: the most EXP a minted mon has
# ever legitimately reported. EXP never decreases in normal play, so a reported EXP below
# the high-water is a save-rollback / edit (a distinct signal from D4, which bounds EXP
# INCREASES). It is also the store the D6 part-2 `on` mode will reconcile the client's
# party against. uid FKs the monsters registry (cascade); one row per mon.
Sequel.migration do
  change do
    create_table(:monster_stats) do
      foreign_key :uid, :monsters, type: :Bignum, primary_key: true, on_delete: :cascade
      Bignum    :exp,   null: false           # high-water cumulative EXP
      Integer   :level, null: false           # level at the high-water EXP
      # A LATCH so a rollback is flagged ONCE per high-water, not on every projection
      # frame while below it: a single no-fault crash (restored save behind the live
      # high-water) would otherwise re-flag a dozen times. Cleared when EXP climbs back
      # to/above the high-water (a genuinely new rollback then re-flags).
      TrueClass :rollback_flagged, null: false, default: false
      DateTime  :first_at,   null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime  :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

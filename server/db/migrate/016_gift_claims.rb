# frozen_string_literal: true

# Audit item 4 (second half) — NPC gift / event-granted items. Layer C gates ONLY
# pbItemBall; every other acquisition (NPC gifts, TMs, HMs, key items, story rewards)
# goes through pbReceiveItem, which was hooked NOWHERE. Combined with client-owned
# self-switches, that made every one-shot reward re-farmable with zero detection.
#
# One row per (account, map, event, item) with a claim COUNT — the re-farm signature
# is the same one-shot event granting the same item over and over. DETECTION only:
# some games legitimately have repeatable/daily gift NPCs, so a repeat is a signal for
# a human (via D5), never an automatic consequence.
Sequel.migration do
  change do
    create_table(:gift_claims) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer   :map,      null: false
      Integer   :event,    null: false
      String    :item,     null: false
      Integer   :quantity, null: false, default: 1   # of the LATEST claim
      Integer   :claims,   null: false, default: 1   # how many times it has been granted
      DateTime  :first_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime  :last_at,  null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[account_id map event item], unique: true, name: :gift_claims_once
    end
  end
end

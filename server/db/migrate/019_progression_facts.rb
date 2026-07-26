# frozen_string_literal: true

# Sovereign variables step 4 - the grant-only progression ledger.
#
# A fact is a monotonic progression marker: a fact-tier switch that went ON, or a
# self-switch that fired. Facts are stored as a set and never removed by the
# application, so a client rollback cannot erase one. That is what makes rewind
# DETECTION unnecessary here: the rewind stops existing rather than being caught
# after the event.
#
# fact_key is NAME-derived for switches ("sw:defeated_gym_1") because the compiler
# renumbers ids; the current id is resolved from the manifest at login. Self-switches
# key on their engine coordinates ("ss:5:2:A"), which are stable by construction.
#
# revoked_at is operator-only - nothing in the request path writes it.
Sequel.migration do
  change do
    create_table(:progression_facts) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :fact_key,   null: false
      DateTime :first_at,   null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :revoked_at, null: true

      primary_key %i[account_id fact_key]
    end
  end
end

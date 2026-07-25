# frozen_string_literal: true

# Audit item 5 — the server-owned PER-MON STAT BLOCK. Until now there was no server
# representation of a Pokémon's stats ANYWHERE: `monsters` rows carry species/level/pid
# AT ISSUE only (migration 005 documents those as allowed-to-go-stale), and D1's team
# audit checked a client-self-reported team with NO uid binding — so it validated stats
# belonging to nobody. That is why a counterfeit mon could carry a valid uid, valid
# provenance and a clean verify_state, and why ranked PvP (D9) would rank unverifiable
# teams. This is D9's real prerequisite, and it is not part of D9.
#
# THE MECHANISM — a FIRST-SIGHT LOCK on the traits the game itself never changes:
#   * IVs are set at creation and only ever rise to 31 (Hyper Training).
#   * shininess and gender derive from the personalID and are fixed for life.
# The server records the block the first time it sees a uid, then any later report that
# violates those invariants is a counterfeit or an edit. Everything else — level, EXP,
# EVs, moves, ability, held item, nature, species (evolution!), form — legitimately
# changes in normal play and is RECORDED but never judged.
#
# Same shape as monster_stats (D6): one row per uid, FK to the registry, cascade.
Sequel.migration do
  change do
    create_table(:monster_blocks) do
      foreign_key :uid, :monsters, type: :Bignum, primary_key: true, on_delete: :cascade
      String    :species,  null: false               # form-resolved id at first sight
      Integer   :level,    null: false
      column    :ivs,      :jsonb, null: false       # {"HP"=>31,...} — the locked trait
      column    :evs,      :jsonb, null: false
      column    :moves,    :jsonb, null: false
      String    :ability,  null: true
      String    :nature,   null: true
      String    :item,     null: true
      TrueClass :shiny,    null: false, default: false   # locked
      Integer   :gender,   null: true                    # locked
      TrueClass :diverged, null: false, default: false   # an invariant was violated
      column    :flags,    :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      DateTime  :first_at,   null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime  :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :diverged   # operator: SELECT ... WHERE diverged
    end
  end
end

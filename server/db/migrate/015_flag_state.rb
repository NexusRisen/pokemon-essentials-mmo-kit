# frozen_string_literal: true

# Audit item 4 (2026-07-25) — THE north-star gap: RPG-Maker switches, variables and
# self-switches (quest progression, story flags, every one-shot event marker) had NO
# server representation at all. 5000 switches + 5000 variables + every event one-shot
# lived only inside the opaque save bytea, so the server could not even SEE that a
# player rewound their story — and rewinding a self-switch re-farms every NPC gift,
# TM, HM and key item, since pbReceiveItem is gated nowhere.
#
# This is the DETECTION shadow (the `:inv` pattern: an absolute client-pushed snapshot,
# last_seq high-water, flag-never-reject). It does not make the server authoritative —
# that needs the world-vs-player ID partition decision, which is a game-design call.
# What it does buy immediately: the server sees the state, and a self-switch REWIND
# (the re-farm signal) becomes visible instead of silent.
#
# Storage: only NON-DEFAULT entries ride (a switch is false and a variable 0 by
# default), so a real save is a few hundred ids, not 10,000 slots.
#   switches      jsonb — [id, id, ...]            (ids that are ON, ascending)
#   variables     jsonb — {"id" => integer}        (non-zero Integer values only)
#   self_switches jsonb — ["map:event:A", ...]     (keys that are ON, ascending)
Sequel.migration do
  change do
    create_table(:flag_snapshots) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      column    :switches,      :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      column    :variables,     :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column    :self_switches, :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      Bignum    :last_seq,   null: false, default: 0
      TrueClass :truncated,  null: false, default: false   # over the cap -> not judged
      TrueClass :flagged,    null: false, default: false
      column    :flags,      :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      DateTime  :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      primary_key [:account_id]   # one flag shadow per account (mirrors inventory_snapshots)
    end
  end
end

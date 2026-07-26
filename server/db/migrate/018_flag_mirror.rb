# frozen_string_literal: true

# Sovereign variables step 3 — THE TRUST GATE's storage. The client now sends every
# intercepted write as a DELTA; the server applies those onto a mirror kept beside the
# absolute snapshot, and when the next snapshot lands the two are compared. Agreement
# across real play is what proves the interception is complete — and only then may the
# server be given authority over this state.
#
# mirror       — flat {"sw/42" => true, "ss/5:2:A" => true, "var/7" => 3} built from
#                deltas alone. Flat because it is diffed, never iterated by section.
# mirror_valid — false after an overflowed delta (we KNOW the mirror is incomplete, so
#                comparing would report a divergence that is ours, not the client's).
#                The next absolute snapshot re-seeds and re-validates it.
# drift_at / drift — the last measured disagreement, for the operator report. This is
#                telemetry about OUR OWN correctness, not about the player.
Sequel.migration do
  change do
    alter_table(:flag_snapshots) do
      add_column :mirror,       :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      add_column :mirror_valid, TrueClass, null: false, default: false
      add_column :drift_at,     DateTime, null: true
      add_column :drift,        String,   null: true
    end
  end
end

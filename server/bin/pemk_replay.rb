# frozen_string_literal: true

# M4 Layer D D7 part 2 — the corpus replay runner. A DEDICATED process (never the
# live server): boots the headless engine once, replays pending battle_records
# against it, and stamps replay_status = match | mismatch | error.
#
# Usage (WSL):
#   DATABASE_URL=postgres://... bundle exec ruby bin/pemk_replay.rb
# Env knobs:
#   PEMK_GAME_ROOT   game repo root (default: the server dir's parent)
#   REPLAY_LIMIT     max records per run (default 100)
#   REPLAY_ID        replay exactly one record id
#   REPLAY_DRY       "on" -> print verdicts, do not update rows

server_root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
$LOAD_PATH.unshift(File.expand_path("../protocol", server_root))

require "sequel"
require "pemk_wire"
require "pemk_prng"
require_relative "../harness/harness"

game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", server_root)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
files = PEMK::Harness.boot!(game_root: game_root)
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts format("harness: engine booted (%d files, %.2fs)", files, t1 - t0)

db  = Sequel.connect(ENV.fetch("DATABASE_URL"))
dry = ENV["REPLAY_DRY"].to_s.downcase == "on"

# Replayable statuses only. walk_mismatch / no_log / mode_mismatch are TRIAGE
# evidence — never silently overwritten; REPLAY_ID alone still respects that
# (REPLAY_FORCE=on to override, e.g. after a triage decision).
REPLAYABLE = %w[pending walk_ok walk_skipped].freeze
ds = db[:battle_records].where(replay_status: REPLAYABLE)
if ENV["REPLAY_ID"]
  ds = db[:battle_records].where(id: ENV["REPLAY_ID"].to_i)
  ds = ds.where(replay_status: REPLAYABLE) unless ENV["REPLAY_FORCE"].to_s.downcase == "on"
end
rows = ds.order(:id).limit((ENV["REPLAY_LIMIT"] || 100).to_i).all
puts "replay: #{rows.length} record(s) queued#{dry ? ' (DRY RUN)' : ''}"

tally = Hash.new(0)
rows.each do |row|
  rec = PEMK::Wire.decode_primitive(row[:record].to_s)
  result =
    if rec.is_a?(Hash)
      PEMK::Harness.replay(rec)
    else
      { verdict: :error, detail: "record body undecodable" }
    end
  status = { match: "match", mismatch: "mismatch", error: "error",
             skipped: "not_replayable" }.fetch(result[:verdict])
  db[:battle_records].where(id: row[:id]).update(replay_status: status) unless dry
  tally[result[:verdict]] += 1
  line = "  ##{row[:id]} #{row[:mode]} outcome=#{row[:outcome]} rounds=#{row[:rounds]}: #{result[:verdict].to_s.upcase}"
  line += " — #{result[:detail]}" if result[:detail]
  puts line
end

total = rows.length
puts format("replay: done — %d match / %d mismatch / %d error of %d (parity %.1f%%)",
            tally[:match], tally[:mismatch], tally[:error], total,
            total.zero? ? 0.0 : (100.0 * tally[:match] / total))

# --- D7 part 3: whole-corpus parity report -----------------------------------
puts "corpus: status breakdown"
db[:battle_records].group_and_count(:replay_status, :mode)
                   .order(:replay_status, :mode).each do |r|
  puts format("  %-16s %-8s %d", r[:replay_status], r[:mode], r[:count])
end

# Per engine-build cohort: parity = match / (match + mismatch). A cohort whose
# parity collapses is a fork/version drift (or a cheat cluster) — part 3's core
# triage signal.
puts "corpus: parity by engine cohort"
db[:battle_records].where(replay_status: %w[match mismatch])
                   .group_and_count(:engine_fp, :replay_status).all
                   .group_by { |r| r[:engine_fp] }.each do |fp, rs|
  m  = rs.find { |r| r[:replay_status] == "match" }&.fetch(:count) || 0
  mm = rs.find { |r| r[:replay_status] == "mismatch" }&.fetch(:count) || 0
  puts format("  %-18s %4d match / %4d mismatch (%.1f%%)",
              (fp || "unknown")[0, 16], m, mm, m + mm > 0 ? 100.0 * m / (m + mm) : 0.0)
end

# frozen_string_literal: true

# Subprocess body for harness_replay_test.rb: boot the headless engine, replay
# each fixture record given as an argv path, print one JSON line of verdicts
# LAST (test parses the last line; boot noise may precede it).

server_root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
$LOAD_PATH.unshift(File.expand_path("../protocol", server_root))

require "json"
require "pemk_wire"
require "pemk_prng"
require_relative "../../harness/harness"

game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", server_root)
PEMK::Harness.boot!(game_root: game_root)

verdicts = ARGV.map do |path|
  rec = PEMK::Wire.decode_primitive(File.binread(path))
  res = rec.is_a?(Hash) ? PEMK::Harness.replay(rec) : { verdict: :error, detail: "undecodable fixture" }
  { fixture: path, verdict: res[:verdict].to_s, detail: res[:detail] }
end

puts JSON.generate(verdicts)

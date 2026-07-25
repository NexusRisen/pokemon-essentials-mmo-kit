require "minitest/autorun"
require "json"
require "rbconfig"

# M4 Layer D D7 part 2: the headless harness replays REAL captured battle records
# (fixtures exported from validated in-game battles — one plain win, one Sleep
# Powder -> Master Ball catch) and must reproduce them exactly. The engine loads
# hundreds of globals/classes, so the harness runs in a SUBPROCESS — never in
# this test process.
class HarnessReplayTest < Minitest::Test
  SERVER_ROOT = File.expand_path("..", __dir__)
  RUNNER      = File.join(SERVER_ROOT, "test", "support", "harness_replay_runner.rb")
  FIXTURES    = Dir[File.join(SERVER_ROOT, "test", "fixtures", "battle_records", "*.bin")].sort

  def test_fixture_records_replay_to_match
    refute_empty FIXTURES, "no battle_record fixtures found"
    game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", SERVER_ROOT)
    unless File.exist?(File.join(game_root, "Data", "types.dat"))
      skip "game Data/*.dat not compiled (launch the game once) — harness replay skipped"
    end

    out = IO.popen([RbConfig.ruby, "-W0", RUNNER, *FIXTURES], err: %i[child out], &:read)
    assert $?.success?, "harness runner failed:\n#{out}"

    verdicts = JSON.parse(out.lines.last)
    assert_equal FIXTURES.length, verdicts.length
    verdicts.each do |v|
      assert_equal "match", v["verdict"],
                   "#{File.basename(v['fixture'])} diverged: #{v['detail']}\n#{out}"
    end
  end
end

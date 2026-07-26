require "minitest/autorun"
require "json"
require "rbconfig"

# The FIRST behavioural test of client plugin code. The audit flagged that 6.6k lines
# of plugin — the code that adopts every enforcement decision and writes into live
# player saves — had no automated verification beyond `ruby -c`, and today proved the
# point: methods defined outside `module_function`, calls to names that did not exist,
# and a silently-disabled interception all shipped past a green syntax check.
#
# The plugins are loaded in a SUBPROCESS under minimal engine stubs, so nothing here
# pollutes the server test process.
class FlagPluginTest < Minitest::Test
  RUNNER = File.join(File.expand_path("..", __dir__), "test", "support", "flag_plugin_runner.rb")

  def test_the_flag_plugins_behave
    out = IO.popen([RbConfig.ruby, "-W0", RUNNER], err: %i[child out], &:read)
    assert $?.success?, "plugin runner crashed:\n#{out}"

    results = JSON.parse(out.lines.last)
    refute_empty results
    failures = results.reject { |_, v| v == "ok" }
    assert_empty failures, "client plugin behaviour failed:\n" \
                           "#{failures.map { |k, v| "  #{k}: #{v}" }.join("\n")}\n\n#{out}"
  end
end

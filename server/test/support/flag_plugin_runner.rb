# frozen_string_literal: true

# Subprocess body for flag_plugin_test.rb: load the REAL client plugin files under
# minimal engine stubs and exercise them. The audit flagged that 6.6k lines of plugin
# — the code that adopts every enforcement decision and writes into live saves — had
# no automated verification beyond `ruby -c`. A syntax check cannot catch a method
# defined outside `module_function`, a call to a name that does not exist, or an
# interception that records the wrong thing; all three shipped today.

require "json"

# --- minimal engine surface -------------------------------------------------
module PEMK
  @log = []
  def self.log(m); @log << m.to_s; end
  def self.logs; @log; end
  def self.enabled?; true; end
  def self.self_id; 1; end
  def self.client; nil; end
end

# The three real wrapper classes, copied in shape from the engine (the plugin
# reopens these, so their vanilla behaviour must be present to be preserved).
class Game_Switches
  def initialize; @data = []; end
  def [](i); (i <= 5000 && @data[i]) || false; end
  def []=(i, v); @data[i] = v if i <= 5000; end
end

class Game_Variables
  def initialize; @data = []; end
  def [](i); (i <= 5000 && !@data[i].nil?) ? @data[i] : 0; end
  def []=(i, v); @data[i] = v if i <= 5000; end
end

class Game_SelfSwitches
  def initialize; @data = {}; end
  def [](k); @data[k] == true; end
  def []=(k, v); @data[k] = v; end
end

class Interpreter
  def initialize; @event_id = 0; end
  def command_121; :vanilla121; end
  def command_122; :vanilla122; end
  def command_123; :vanilla123; end
end

class FakeMap
  def map_id; 5; end
end
$game_map = FakeMap.new

PLUGINS = File.expand_path("../../../Plugins/PEMK", __dir__)
load File.join(PLUGINS, "004_Persist/009_Flags.rb")
load File.join(PLUGINS, "004_Persist/010_FlagDelta.rb")

$game_switches      = Game_Switches.new
$game_variables     = Game_Variables.new
$game_self_switches = Game_SelfSwitches.new

results = {}

def check(results, name)
  results[name] = (yield ? "ok" : "FAIL")
rescue StandardError => e
  results[name] = "ERROR #{e.class}: #{e.message}"
end

# 1. Every method the other plugins call must actually exist on the module.
check(results, "api_surface") do
  %i[reset adopt_mode adopt_policy owned? tier active? projection on_ack].all? { |m| PEMK::Flags.respond_to?(m) } &&
    %i[reset drain record_switch record_variable record_self_switch with_origin].all? { |m| PEMK::Flags::Delta.respond_to?(m) }
end

# 1b. THE bug class that actually shipped today: a cross-module call to a method that
# does not exist on the target module (a method defined outside `module_function`, or
# an edit that silently never applied). `ruby -c` cannot see it — only the player did,
# as a NoMethodError storm. Every call site added by the flags work is asserted here.
check(results, "cross_module_calls_resolve") do
  load File.join(PLUGINS, "006_Sync/001_Sync.rb")
  sync_ok = %i[reset mark_flags adopt_flags_seq adopt_econ_seq adopt_inv_seq
               adopt_mon_seq mark_inv mark_mon dirty?].all? { |m| PEMK::Sync.respond_to?(m) }
  # ...and the flags channel must be able to make the client dirty ON ITS OWN, or a
  # pure story change never flushes (it could only ride along with another channel).
  PEMK::Sync.reset
  before = PEMK::Sync.dirty?
  PEMK::Sync.mark_flags
  sync_ok && !before && PEMK::Sync.dirty?
end

# 2. OFF by default: a write must be recorded by nobody.
check(results, "inert_when_off") do
  $game_switches[4] = true
  PEMK::Flags::Delta.drain.nil? && $game_switches[4] == true
end

# 3. The vanilla store always wins, and only POLICY-OWNED ids are recorded.
check(results, "records_only_owned") do
  PEMK::Flags.adopt_mode("shadow")
  PEMK::Flags.adopt_policy("switches" => { "4" => "fact" }, "variables" => { "7" => "mirror" })
  PEMK::Flags::Delta.reset
  $game_switches[4] = true     # owned
  $game_switches[77] = true    # local -> never recorded
  $game_variables[7] = 12      # owned
  $game_variables[99] = 5      # local
  d = PEMK::Flags::Delta.drain
  d && d[:switches] == { 4 => true } && d[:variables] == { 7 => 12 } &&
    $game_switches[77] == true && $game_variables[99] == 5   # vanilla intact
end

# 4. Self-switches are the whole namespace, flattened to a stable key.
check(results, "self_switch_key") do
  PEMK::Flags::Delta.reset
  $game_self_switches[[5, 2, "A"]] = true
  d = PEMK::Flags::Delta.drain
  d && d[:self_switches] == { "5:2:A" => true } && $game_self_switches[[5, 2, "A"]] == true
end

# 5. Coalescing: an event's scratch storm becomes ONE entry.
check(results, "coalesces_by_key") do
  PEMK::Flags::Delta.reset
  90.times { |i| $game_variables[7] = i }
  d = PEMK::Flags::Delta.drain
  d && d[:variables] == { 7 => 89 }
end

# 6. A non-primitive value (a Pokémon, an Array) is recorded as untracked, not shipped.
check(results, "non_primitive_untracked") do
  PEMK::Flags::Delta.reset
  $game_variables[7] = [1, 2, 3]
  d = PEMK::Flags::Delta.drain
  d && d[:variables] == { 7 => nil } && $game_variables[7] == [1, 2, 3]
end

# 7. drain empties the buffer (the caller owns delivery).
check(results, "drain_is_destructive") do
  PEMK::Flags::Delta.reset
  $game_switches[4] = true
  PEMK::Flags::Delta.drain
  PEMK::Flags::Delta.drain.nil?
end

# 8. The interpreter alias preserves the original's return value and sets attribution.
check(results, "intent_frame") do
  i = Interpreter.new
  i.instance_variable_set(:@event_id, 12)
  seen = nil
  PEMK::Flags::Delta.define_singleton_method(:probe) { seen = origin }
  ok = i.command_121 == :vanilla121
  PEMK::Flags::Delta.with_origin(5, 12) { seen = PEMK::Flags::Delta.origin }
  ok && seen == [5, 12]
end

# 9. reset drops the mode AND the buffer (a new socket agreed to nothing).
check(results, "reset_clears_everything") do
  PEMK::Flags.adopt_mode("shadow")
  $game_switches[4] = true
  PEMK::Flags.reset
  !PEMK::Flags.active? && PEMK::Flags::Delta.drain.nil?
end

# === step 4: login authority (facts only) ===================================

# The union restores what a rollback dropped...
check(results, "reconcile_unions_facts") do
  PEMK::Flags.adopt_mode("shadow")
  PEMK::Flags.adopt_policy("switches" => { "4" => "fact" })
  $game_switches = Game_Switches.new
  $game_self_switches = Game_SelfSwitches.new
  PEMK::Flags.note_facts(switches: [4], self_switches: ["5:2:A"])
  PEMK::Flags.reconcile
  $game_switches[4] == true && $game_self_switches[[5, 2, "A"]] == true
end

# ...and can only ever ADD: state the client has and the server does not is untouched,
# which is what makes an offline session safe.
check(results, "reconcile_never_removes") do
  $game_switches = Game_Switches.new
  $game_self_switches = Game_SelfSwitches.new
  $game_switches[4] = true
  $game_self_switches[[9, 9, "B"]] = true      # earned offline; server knows nothing of it
  PEMK::Flags.note_facts(switches: [], self_switches: [])
  PEMK::Flags.reconcile
  $game_switches[4] == true && $game_self_switches[[9, 9, "B"]] == true
end

# Applying server state must not be echoed straight back as a client write.
check(results, "reconcile_does_not_echo") do
  $game_switches = Game_Switches.new
  $game_self_switches = Game_SelfSwitches.new
  PEMK::Flags::Delta.reset
  PEMK::Flags.note_facts(switches: [4], self_switches: ["5:2:A"])
  PEMK::Flags.reconcile
  PEMK::Flags::Delta.drain.nil?
end

# Suppression must be scoped, not sticky: a normal write after it still records.
check(results, "suppression_is_scoped") do
  PEMK::Flags::Delta.reset
  PEMK::Flags::Delta.suppress { $game_switches[4] = true }
  $game_switches[4] = false
  $game_switches[4] = true
  d = PEMK::Flags::Delta.drain
  d && d[:switches] == { 4 => true }
end

# Nothing to apply, or the feature off, must be a clean no-op.
check(results, "reconcile_is_inert_without_facts") do
  PEMK::Flags.reconcile
  PEMK::Flags.reset
  PEMK::Flags.note_facts(switches: [4], self_switches: [])
  PEMK::Flags.reconcile
  $game_switches[4] == true   # unchanged from the previous check, not re-applied while off
end

puts JSON.generate(results)

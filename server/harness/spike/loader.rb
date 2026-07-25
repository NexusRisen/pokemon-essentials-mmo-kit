# D7 STEP-0 GATE spike — loads real Essentials v21.1 scripts on plain MRI 3.1.
# Usage: ruby -W0 loader.rb

T_START = Process.clock_gettime(Process::CLOCK_MONOTONIC)

require_relative "stubs"

SCRIPTS = File.join(PEMK_ROOT, "Data/Scripts")

def load_script(rel)
  path = File.join(SCRIPTS, rel)
  raise "missing script #{path}" if !File.exist?(path)
  Kernel.load(path)
rescue Exception => e
  STDERR.puts "LOAD FAILED in: #{rel}"
  raise
end

# --- Ordered script list -----------------------------------------------------
ordered = []

# Settings (constants used throughout battle code)
ordered << "001_Settings.rb"
ordered << "002_BattleSettings.rb"

# HandlerHash infra + event handler collections
ordered << "003_Game processing/005_Event_Handlers.rb"
ordered << "003_Game processing/006_Event_HandlerCollections.rb"

# GameData model + hardcoded data + needed PBS data classes
ordered << "010_Data/001_GameData.rb"
Dir.glob(File.join(SCRIPTS, "010_Data/001_Hardcoded data/*.rb")).sort.each do |f|
  ordered << f.sub(SCRIPTS + "/", "")
end
%w[003_Type 004_Ability 005_Move 006_Item 008_Species 010_SpeciesMetrics
   012_Ribbon 014_TrainerType].each do |f|
  ordered << "010_Data/002_PBS data/#{f}.rb"
end

# Pokemon class tree
ordered << "014_Pokemon/001_Pokemon-related/001_FormHandlers.rb"
ordered << "014_Pokemon/001_Pokemon.rb"
ordered << "014_Pokemon/002_Pokemon_MegaEvolution.rb"
ordered << "014_Pokemon/003_Pokemon_ShadowPokemon.rb"
ordered << "014_Pokemon/004_Pokemon_Move.rb"
ordered << "014_Pokemon/005_Pokemon_Owner.rb"

# Trainer classes (Trainer + NPCTrainer + Player, which Pokemon#initialize case-matches)
ordered << "015_Trainers and player/001_Trainer.rb"
ordered << "015_Trainers and player/004_Player.rb"

# Battle engine: everything except 004_Scene, but with 009_Battle_DebugScene.rb
%w[001_Battle 002_Battler 003_Move].each do |dir|
  Dir.glob(File.join(SCRIPTS, "011_Battle/#{dir}/*.rb")).sort.each do |f|
    ordered << f.sub(SCRIPTS + "/", "")
  end
end
ordered << "011_Battle/004_Scene/009_Battle_DebugScene.rb"
ordered << :scene_shell   # marker — define an empty Battle::Scene for 008_Other battle types
["005_AI", "006_AI MoveEffects", "007_Other battle code", "008_Other battle types"].each do |dir|
  Dir.glob(File.join(SCRIPTS, "011_Battle/#{dir}/*.rb")).sort.each do |f|
    ordered << f.sub(SCRIPTS + "/", "")
  end
end

ordered.each do |rel|
  if rel == :scene_shell
    # 008_Other battle types (Safari/BugContest) reopen Battle::Scene subclasses
    # at load time. Give them an inert shell; nothing visual ever runs.
    Battle.class_eval <<~RUBY
      class Scene
        # Auto-vivify unknown nested constants (Animation etc.) as inert classes
        # so 008_Other battle types can subclass them at load time.
        def self.const_missing(name)
          if name.to_s.end_with?("Mixin")
            const_set(name, Module.new)
          else
            const_set(name, Class.new do
              def initialize(*args); end
              def method_missing(name, *args); nil; end
              def respond_to_missing?(*); true; end
              def self.const_missing(name)
                if name.to_s.end_with?("Mixin")
                  const_set(name, Module.new)
                else
                  const_set(name, Class.new(self))
                end
              end
            end)
          end
        end
        def method_missing(name, *args); nil; end
        def respond_to_missing?(*); true; end
        # Real methods 008_Other battle types aliases at load time:
        def pbThrowSuccess; end
        def pbInitSprites; end
      end
    RUBY
    next
  end
  load_script(rel)
end

T_SCRIPTS = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts format("SCRIPTS LOADED: %d files in %.2fs", ordered.length, T_SCRIPTS - T_START)

# --- GameData .dat loading ---------------------------------------------------
[GameData::Type, GameData::Ability, GameData::Move, GameData::Item,
 GameData::Species, GameData::SpeciesMetrics, GameData::Ribbon,
 GameData::TrainerType].each do |klass|
  klass.load
  puts format("  %-28s %d entries", klass.name, klass::DATA.length)
end

T_DATA = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts format("GAMEDATA LOADED in %.2fs", T_DATA - T_SCRIPTS)

# --- Run the battle ----------------------------------------------------------
require_relative "run_battle"

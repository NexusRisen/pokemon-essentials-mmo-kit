# frozen_string_literal: true

# M4 Layer D D7 part 2 — the HEADLESS BATTLE HARNESS. Boots the real Essentials
# battle engine (unmodified, from the game repo's Data/Scripts) on plain MRI and
# replays D7 battle records against it. One boot per process (~1.6s), then each
# replay costs milliseconds.
#
# THIS IS A DEDICATED PROCESS (bin/pemk_replay.rb) — never loaded into the live
# reactor server: the engine defines hundreds of globals/classes that must not
# share a process with the authoritative server.
module PEMK
  module Harness
    class << self
      def booted?; @booted == true; end

      # Idempotent. +game_root+ = the repo root holding Data/Scripts and Data/*.dat.
      def boot!(game_root:)
        return 0 if booted?

        # Tripwire: the engine's globals/classes must NEVER share a process with
        # the authoritative server (isolation was convention-only — review-caught).
        if defined?(::PEMK::Server) || defined?(::PEMK::Reactor)
          raise "harness: refusing to load the battle engine inside the live server process"
        end
        raise "harness: no Data/Scripts under #{game_root}" unless File.directory?(File.join(game_root, "Data", "Scripts"))

        Object.const_set(:PEMK_ROOT, game_root) unless defined?(::PEMK_ROOT)
        require_relative "stubs"
        require_relative "engine_loader"
        files = load_engine!(File.join(game_root, "Data", "Scripts"))
        load_gamedata!
        post_patches!
        require_relative "replay"
        @booted = true
        files
      end
    end
  end
end

#===============================================================================
# PEMK :: Flags  (client side — the switches/variables/self-switches projection)
#-------------------------------------------------------------------------------
# The north-star gap the audit named: RPG-Maker switches, variables and self-
# switches — quest progression, story flags and every one-shot event marker —
# had NO server representation at all. They lived only inside the opaque save
# blob, so the server could not even SEE that a player rewound their story; and
# rewinding a self-switch re-arms every NPC gift, TM, HM and key-item event.
#
# This projects the NON-DEFAULT set (a switch is false and a variable 0 by
# default), so a real save is a few hundred ids rather than 10,000 slots. It is
# a DETECTION shadow — the server records it and flags a rewind, it does not
# correct anything. Making the server authoritative here needs the world-vs-
# player ID partition, which is a game-design decision.
#
# Reads the ivars directly (the engine classes are plain @data wrappers) so no
# engine file is touched and no accessor is added to core.
#===============================================================================
module PEMK
  module Flags
    MAX_ENTRIES = 4000   # mirrors the server cap; beyond it the snapshot isn't judged

    @mode = :off
    # The tier table, pushed by the server at login (it owns the build-time manifest,
    # so both sides provably agree). Only NON-LOCAL ids travel — everything absent is
    # local, which is the pre-sovereignty behaviour, so a missing policy makes the
    # whole layer inert rather than wrong.
    @tiers = { :switches => {}, :variables => {} }

    module_function

    def reset
      @mode = :off
      @tiers = { :switches => {}, :variables => {} }
      (PEMK::Flags::Delta.reset rescue nil)
    end

    # policy: { "switches" => {"4"=>"fact", ...}, "variables" => {"7"=>"mirror"} }
    def adopt_policy(policy)
      t = { :switches => {}, :variables => {} }
      if policy.is_a?(Hash)
        %w[switches variables].each do |kind|
          sec = policy[kind]
          next unless sec.is_a?(Hash)

          sec.each { |id, tier| t[kind.to_sym][id.to_i] = tier.to_s if id.to_i.positive? }
        end
      end
      @tiers = t
      PEMK.log("flags: adopted policy (#{t[:switches].size} switches, #{t[:variables].size} variables)")
    end

    # Is this id the server's business? Absent => local => never recorded, never sent.
    def owned?(kind, id)
      return false unless active? && id.is_a?(Integer)

      !@tiers[kind].nil? && !@tiers[kind][id].nil?
    end

    def tier(kind, id)
      (@tiers[kind] || {})[id] || "local"
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end
    def active?; @mode != :off; end

    # -> { :switches => [id,...], :variables => {id_string => int}, :self_switches => ["m:e:A",...] }
    # nil when the game state isn't loaded yet (never send a half-built snapshot).
    def projection
      return nil unless $game_switches && $game_variables && $game_self_switches

      { :switches      => on_switches,
        :variables     => set_variables,
        :self_switches => on_self_switches }
    rescue => e
      PEMK.log("flags: projection error: #{e.class}: #{e.message}")
      nil
    end

    def on_switches
      data = $game_switches.instance_variable_get(:@data) || []
      out  = []
      data.each_with_index do |v, i|
        next unless v
        out << i
        break if out.length >= MAX_ENTRIES
      end
      out
    end

    # Only Integer values are projected: they are the ones the server can compare,
    # and they cover quest counters. Non-Integer variables (strings, arrays a fan
    # script parked there) are deliberately skipped rather than shipped blindly.
    def set_variables
      data = $game_variables.instance_variable_get(:@data) || []
      out  = {}
      data.each_with_index do |v, i|
        next unless v.is_a?(Integer) && v != 0
        out[i.to_s] = v
        break if out.size >= MAX_ENTRIES
      end
      out
    end

    # Keys are [map_id, event_id, "A"] -> flattened to "map:event:A" (compact,
    # primitive-codec friendly, and stable to sort/diff server-side).
    def on_self_switches
      data = $game_self_switches.instance_variable_get(:@data) || {}
      out  = []
      data.each do |k, v|
        next unless v == true && k.is_a?(Array) && k.length >= 3
        out << "#{k[0]}:#{k[1]}:#{k[2]}"
        break if out.length >= MAX_ENTRIES
      end
      out
    end

    # :flags_ack is telemetry — log a server flag, never write anything back.
    def on_ack(msg)
      PEMK.log("flags: server flagged a state rewind (seq #{msg[:seq]})") if msg && msg[:flagged]
    end
  end
end

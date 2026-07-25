#===============================================================================
# PEMK :: ExpCorrect  (client side — M4 Layer D D6 part 2, server EXP restore)
#-------------------------------------------------------------------------------
# Applies the server's UP-ONLY EXP corrections when EXP enforcement is :on: the
# :mon_ack reply may carry :exp_correct = [{uid, exp}] for party mons the server
# saw BELOW their EXP high-water (an old save reloaded — or a crash's earned-but-
# lost EXP, which this hands back). Each listed mon is raised to the server's
# high-water — NEVER lowered — on the next safe overworld frame (never mid-battle
# / menu / transfer / running event, mirroring PosCorrect), then re-projected +
# checkpointed so the restore persists and the server stops correcting.
#
# Deliberately NO forced evolution and NO forced move-learning: both pop blocking
# UI on a background frame (soft-lock risk). The mon evolves on its next natural
# level-up; the Move Reminder covers any skipped level-up moves.
#
# Hard-won guards (adversarial review):
#   - a fainted mon STAYS fainted (calc_stats' HP top-up would revive it);
#   - SHADOW mons are skipped: their exp= override diverts the write into
#     @saved_exp without touching @exp — applying would loop forever and inflate
#     the purification payout (they restore normally once purified);
#   - the write is VERIFIED (pkmn.exp >= target) so any other fan-plugin exp=
#     override fails once and is skipped for the session instead of looping;
#   - the target is clamped to the mon's own growth-curve maximum (a hostile /
#     misconfigured server can never write an impossible EXP into the save), and
#     held 1 EXP short of the cap when the species can still evolve (a mon parked
#     exactly AT max level could never level-up-evolve in Gen<=7 forks).
#
# Dormant unless the server advertises battle_enforce_exp=on (default off); the
# up-only guard makes a stale or re-sent correction a no-op.
#===============================================================================
module PEMK
  module ExpCorrect
    @mode     = :off          # server-advertised D6 mode (adopted at login/relogin)
    @pending  = {}            # uid => target_exp awaiting a safe frame (newest wins)
    @skip     = {}            # uid => true — exp= write didn't take (override); no retry this session
    @attempts = Hash.new(0)   # uid => transient-error retries (capped)

    module_function

    def reset
      @mode     = :off
      @pending  = {}
      @skip     = {}
      @attempts = Hash.new(0)
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    # From Monsters.on_ack on an inbound :exp_correct list. Store; apply on the
    # next safe frame. A newer target supersedes an unapplied older one.
    def request(list)
      return unless @mode == :on && list.is_a?(Array)

      list.each do |c|
        next unless c.is_a?(Hash) && c[:uid].is_a?(Integer) && c[:exp].is_a?(Integer) && c[:exp] > 0
        @pending[c[:uid]] = c[:exp]
      end
    end

    def tick
      return if @pending.empty?
      return unless safe?

      todo = @pending
      @pending = {}
      applied = 0
      todo.each do |uid, target|
        case apply(uid, target)
        when :applied
          applied += 1
        when :error
          # transient (scene raced the safe check, etc.) -> retry a few frames, then drop;
          # the server re-emits on the next projection anyway.
          @attempts[uid] += 1
          @pending[uid] = target if @attempts[uid] < 5
        end
      end
      if applied > 0
        (PEMK::Sync.mark_mon rescue nil)                  # re-project AT the high-water
        (PEMK::Checkpoint.request(:pokemon) rescue nil)   # persist the restore urgently
      end
    rescue => e
      PEMK.log("expcorrect: tick error #{e.class}: #{e.message}")
    end

    # Only in the overworld with nothing else in flight — PosCorrect's gate PLUS
    # no running event / open message box (an event that already branched on a
    # mon's level must not see it change mid-script).
    def safe?
      $scene.is_a?(Scene_Map) && $game_temp && $game_map && $game_player &&
        !$game_temp.in_battle && !$game_temp.in_menu &&
        !$game_temp.player_transferring && !$game_temp.transition_processing &&
        !$game_temp.message_window_showing &&
        !(pbMapInterpreterRunning? rescue false)
    rescue
      false
    end

    # Raise ONE mon to +target+ exp. UP-ONLY and idempotent.
    # -> :applied (changed) | :noop (nothing to do / must not touch) | :error (retry).
    def apply(uid, target)
      return :noop if @skip[uid]

      pkmn = PEMK::Monsters.find_by_uid(uid)
      return :noop unless pkmn && !pkmn.egg?
      return :noop if (pkmn.shadowPokemon? rescue false)   # exp= diverts to @saved_exp — never write

      # Never write beyond this mon's own curve; hold 1 EXP short of the cap when
      # the species can still evolve (see header).
      cap = (pkmn.growth_rate.maximum_exp rescue nil)
      target = cap if cap && target > cap
      if cap && target >= cap && (pkmn.species_data.get_evolutions.any? rescue false)
        target = cap - 1
      end
      return :noop unless pkmn.exp < target

      was_fainted = pkmn.fainted?
      old_level   = pkmn.level
      pkmn.exp = target            # setter nils @level -> lazy level_from_exp recompute
      unless pkmn.exp >= target    # write diverted by an exp= override -> skip forever (no loop)
        @skip[uid] = true
        PEMK.log("expcorrect: uid#{uid} exp= write did not take (override?) — skipped this session")
        return :noop
      end
      pkmn.calc_stats              # stats/HP follow the (possibly) new level
      pkmn.hp = 0 if was_fainted   # calc_stats' HP top-up must NOT revive a fainted mon
      PEMK.log("expcorrect: uid#{uid} exp -> #{target} (lvl #{old_level}->#{pkmn.level})")
      :applied
    rescue => e
      PEMK.log("expcorrect: apply error uid#{uid}: #{e.class}: #{e.message}")
      :error
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_exp_correct,
  proc { PEMK::ExpCorrect.tick })

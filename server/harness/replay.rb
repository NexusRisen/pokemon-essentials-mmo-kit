# frozen_string_literal: true

# M4 Layer D D7 part 2 — REPLAY: re-simulate a captured battle record on the
# headless engine and compare outcomes. Loaded by Harness.boot! AFTER the engine.
#
# Model (mirrors vanilla RecordedBattlePlaybackModule, hardened):
#   - BOTH sides' choices re-register from the record's per-round @choices
#     snapshots (the AI never re-runs — its stream is separate by design).
#   - pbRandom draws from the seed's PCG32 battle stream (`on` records) or
#     value-replays the recorded (bound, value) log (`shadow` records); a bound
#     mismatch against the logged bound is a precise divergence diagnostic.
#   - pbRun re-executes from the :runs event list (the end-of-round
#     "Use next Pokémon?" -> No path is driven by the pending event; the flee
#     roll draws the :r stream).
#   - forced switch-ins pop the recorded returns; @megaEvolution restores from
#     the per-round snapshot.
#   - `on` records replay ball throws with the D3-injected verdict (the server
#     adjudicated the shakes; the final throw of a caught battle returns 4, any
#     other returns 0 — message-only difference, state-exact).
#   - VERDICT: compare decision / turn count / per-mon end HP-status-EXP.
#
# An engine exception during replay is a FAILED replay (:error), never swallowed
# (stubs make PBDebug.logonerr transparent).
module PEMK
  module Harness
    STAT_KEYS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze

    class ReplayDivergence < StandardError; end

    module_function

    # record: the decoded primitive record hash (symbol keys). -> result hash:
    #   { verdict: :match | :mismatch | :error, detail: String | nil }
    def replay(record)
      # Known-incomplete records can never legitimately match — a distinct verdict,
      # not a fake mismatch polluting part-3 parity stats.
      if record[:truncated] == true || record[:desynced] == true
        return { verdict: :skipped, detail: "record marked #{record[:truncated] ? 'truncated' : 'desynced'}" }
      end

      PBDebug::LOG.clear
      $collected_messages.clear
      ctx = ReplayContext.new(record)
      battle = build_battle(ctx)
      battle.pbStartBattle
      compare(ctx, battle)
    rescue ReplayDivergence => e
      { verdict: :mismatch, detail: e.message }
    rescue StandardError => e
      { verdict: :error, detail: "#{e.class}: #{e.message} @ #{Array(e.backtrace)[0]}" }
    ensure
      $game_temp.in_battle = false   # never leak battle state into the next replay
    end

    # --- state rebuild ---------------------------------------------------------

    def build_mon(frame, owner)
      raise ReplayDivergence, "init frame missing" unless frame.is_a?(Hash)

      pkmn = Pokemon.new(frame[:species].to_s.to_sym, frame[:level] || 5, owner, false)
      pkmn.personalID = frame[:pid] if frame[:pid].is_a?(Integer)
      { iv: pkmn.iv, ev: pkmn.ev }.each do |key, target|
        src = frame[key]
        next unless src.is_a?(Hash)

        STAT_KEYS.each do |s|
          v = src[s] || src[s.to_sym]
          target[s.to_sym] = v if v.is_a?(Integer)
        end
      end
      moves = Array(frame[:moves]).map do |id|
        begin
          Pokemon::Move.new(id.to_s.to_sym)
        rescue StandardError
          # compacting would silently misalign the PP list with the slots
          raise ReplayDivergence, "unresolvable move #{id.inspect} in init frame"
        end
      end
      pkmn.moves = moves unless moves.empty?
      Array(frame[:pp]).each_with_index do |pp, i|
        pkmn.moves[i].pp = pp if pp.is_a?(Integer) && pkmn.moves[i]
      end
      pkmn.ability = frame[:ability].to_sym if frame[:ability]
      pkmn.nature  = frame[:nature].to_sym if frame[:nature]
      pkmn.item    = frame[:item] ? frame[:item].to_sym : nil
      pkmn.happiness = frame[:happiness] if frame[:happiness].is_a?(Integer)
      pkmn.gender  = frame[:gender] if frame[:gender].is_a?(Integer)
      pkmn.shiny   = frame[:shiny] == true
      (pkmn.form_simple = frame[:form]) if frame[:form].is_a?(Integer) && frame[:form].positive?
      pkmn.exp = frame[:exp] if frame[:exp].is_a?(Integer)
      pkmn.nature = pkmn.nature   # touch to memoize before stats
      pkmn.calc_stats
      pkmn.hp = frame[:hp] if frame[:hp].is_a?(Integer)
      st = frame[:status].to_s
      pkmn.status = st.to_sym if !st.empty? && st != "NONE" && (GameData::Status.exists?(st.to_sym) rescue false)
      pkmn
    end

    def build_battle(ctx)
      trainer = Player.new("REPLAY", GameData::TrainerType.keys.first)
      trainer.id = 12_345
      player_party = Array(ctx.init[:player]).compact.map { |f| build_mon(f, trainer) }
      foe_party    = Array(ctx.init[:foe]).compact.map { |f| build_mon(f, nil) }
      raise ReplayDivergence, "empty party in init frames" if player_party.empty? || foe_party.empty?

      $player = trainer   # internalBattle needs a player (EXP/catch paths read it)
      scene  = ReplayScene.new(ctx)
      battle = ReplayBattle.new(scene, player_party, foe_party, [trainer], nil)
      battle.pemk_ctx      = ctx
      battle.internalBattle = true
      battle.expGain        = true
      battle.moneyGain      = false   # wild battles pay no money; keep $player untouched
      battle.controlPlayer  = false
      $game_temp.in_battle  = true
      battle
    end

    # --- verdict ---------------------------------------------------------------

    def compare(ctx, battle)
      want = ctx.outcome
      raise ReplayDivergence, "record has no outcome" unless want.is_a?(Hash)

      # The replay must CONSUME the record: an early-ending divergent battle
      # (wrong catch verdict, wrong confirm answer) leaves rounds/runs/switches
      # unconsumed and would otherwise pass every end-state check silently.
      if (left = ctx.leftovers)
        return { verdict: :mismatch, detail: "replay ended early: #{left} unconsumed" }
      end

      # Both sides digest at pbEndOfBattle ENTRY (the recorder's seam) — the ctx
      # snapshot; falling back to live party state only if the seam never fired.
      got = ctx.end_snapshot || live_snapshot(battle)

      if want[:decision] != got[:decision]
        return { verdict: :mismatch, detail: "decision: want #{want[:decision]}, got #{got[:decision]}" }
      end
      if want[:turns].is_a?(Integer) && want[:turns] >= 0 && got[:turns] != want[:turns]
        return { verdict: :mismatch, detail: "turns: want #{want[:turns]}, got #{got[:turns]}" }
      end

      %i[player foe].each do |side|
        Array(want[side]).each_with_index do |w, i|
          next unless w.is_a?(Hash)

          g = (got[side] || [])[i]
          next unless g

          return { verdict: :mismatch, detail: "#{side}[#{i}] hp: want #{w[:hp]}, got #{g[:hp]}" } if w[:hp].is_a?(Integer) && g[:hp] != w[:hp]
          ws = w[:status].to_s
          return { verdict: :mismatch, detail: "#{side}[#{i}] status: want #{ws}, got #{g[:status]}" } if !ws.empty? && g[:status].to_s != ws
          return { verdict: :mismatch, detail: "#{side}[#{i}] exp: want #{w[:exp]}, got #{g[:exp]}" } if w[:exp].is_a?(Integer) && g[:exp] != w[:exp]
        end
      end
      { verdict: :match, detail: nil }
    end

    def live_snapshot(battle)
      { decision: battle.decision, turns: (battle.turnCount rescue -1),
        player: battle.pbParty(0).map { |p| p && { hp: p.hp, status: p.status.to_s, exp: p.exp } },
        foe:    battle.pbParty(1).map { |p| p && { hp: p.hp, status: p.status.to_s, exp: p.exp } } }
    end

    # --- the replay driver -----------------------------------------------------

    # Per-replay mutable state: choice rounds, run events, switch returns, streams.
    class ReplayContext
      attr_reader :record, :init, :outcome, :mode
      attr_accessor :round_index

      def initialize(record)
        @record  = record
        @mode    = record[:mode].to_s
        @init    = record[:init] || {}
        @outcome = record[:outcome]
        @rounds  = Array(record[:rounds])
        @runs    = Array(record[:runs])
        @switches = Array(record[:switches])
        @round_index = -1
        @run_context = false
        @end_snapshot = nil
        seed = record[:seed]
        if @mode == "on"
          raise ReplayDivergence, "on-record without seed" unless seed.is_a?(Integer)

          @prngs = { b: PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE),
                     r: PEMK::Prng.new(seed, PEMK::Prng::STREAM_RUN) }
        else
          @logs = { b: unpack_log(:b), r: unpack_log(:r) }
          @log_pos = { b: 0, r: 0 }
        end
      end

      def unpack_log(key)
        draws = @record[:draws]
        s = draws.is_a?(Hash) && draws[key].is_a?(Hash) ? draws[key][:log] : nil
        s.is_a?(String) ? s.unpack("N*") : []
      end

      attr_accessor :end_snapshot

      def next_round
        @round_index += 1
        @rounds[@round_index]
      end

      def last_round?
        @round_index >= @rounds.length - 1
      end

      # nil when everything was consumed, else a human diagnostic. An early-ending
      # replay (divergence!) leaves entries behind.
      def leftovers
        parts = []
        parts << "#{@rounds.length - 1 - @round_index} round(s)" if @round_index < @rounds.length - 1
        parts << "#{@runs.length} run event(s)" unless @runs.empty?
        parts << "#{@switches.length} switch(es)" unless @switches.empty?
        parts.empty? ? nil : parts.join(", ")
      end

      def run_pending?(during)
        @runs.first && @runs.first[1] == (during ? 1 : 0)
      end

      def pop_run; @runs.shift; end
      def pop_switch; (@switches.shift || [])[1]; end

      def run_context?; @run_context; end
      def with_run_context
        @run_context = true
        yield
      ensure
        @run_context = false
      end

      # One draw for stream :b or :r. `on` -> derive from PRNG; shadow -> value-
      # replay the log, verifying the recorded bound matches the engine's ask.
      def draw(kind, bound)
        if @prngs
          # mirror the recorder's guard exactly — a bound > 2^32 would infinite-
          # loop rand_below, and the recorder fell back to vanilla there (desynced
          # records are short-circuited before replay ever starts)
          unless bound.is_a?(Integer) && bound.positive? && bound <= (1 << 32)
            raise ReplayDivergence, "unreplayable bound #{bound.inspect} on stream #{kind}"
          end

          @prngs[kind].rand_below(bound)
        else
          pos = @log_pos[kind]
          logged_bound = @logs[kind][2 * pos]
          value        = @logs[kind][2 * pos + 1]
          raise ReplayDivergence, "stream #{kind} exhausted at draw #{pos} (bound #{bound})" if value.nil?
          raise ReplayDivergence, "stream #{kind} draw #{pos}: engine asked rand(#{bound}), record logged rand(#{logged_bound})" \
            if logged_bound != (bound.is_a?(Integer) ? bound & 0xFFFFFFFF : 0)

          @log_pos[kind] = pos + 1
          value
        end
      end
    end

    # Scene: DebugSceneNoVisuals + the ONE player prompt replay must answer — the
    # end-of-round "use next Pokémon?" confirm. Answer No exactly when the next
    # pending run event is a during-battle one (that is the only way a No is ever
    # recorded), else Yes.
    class ReplayScene < Battle::DebugSceneNoVisuals
      def initialize(ctx)
        super(false)
        @ctx = ctx
      end

      # Battle#pbDisplayConfirm delegates to the scene's pbDisplayConfirmMessage
      # (NOT pbDisplayConfirm — review-caught dead code). Answer the end-of-round
      # "Use next Pokémon?" prompt with No exactly when a during-battle run event
      # is pending (the only way a No was ever recorded); every other confirm
      # keeps the debug scene's default Yes.
      def pbDisplayConfirmMessage(msg)
        return !@ctx.run_pending?(true) if msg.to_s.include?("Use next Pok")

        true
      end

      # Anything DebugSceneNoVisuals doesn't implement is pure display in a
      # replay (ball-throw animations etc.) — inert. Choice menus never run
      # (choices re-register straight from the record).
      def method_missing(_name, *_args); nil; end
      def respond_to_missing?(*); true; end
    end

    class ReplayBattle < Battle
      attr_accessor :pemk_ctx

      def pbRandom(x)
        @pemk_ctx ? @pemk_ctx.draw(:b, x) : super
      end

      # Register BOTH sides' choices from the record on the player pass; the AI
      # pass is a no-op (vanilla playback pattern). A recorded during-command run
      # event re-executes pbRun instead (its roll draws the :r stream).
      def pbCommandPhaseLoop(isPlayer)
        return unless isPlayer

        round = @pemk_ctx.next_round
        raise ReplayDivergence, "record exhausted: engine wants round #{@pemk_ctx.round_index}" unless round

        choices = round[:c] || []
        @battlers.each_with_index do |b, i|
          next if !b || b.fainted?

          c = choices[i]
          # A command-phase flee attempt leaves a None choice in the snapshot (the
          # run consumed the action) — that None + a pending during=false run event
          # is the run's signature; a None WITHOUT one is genuinely no action.
          # Gating on the None keeps a recorded failed flee in ITS round.
          if pbOwnedByPlayer?(i) && @pemk_ctx.run_pending?(false) && none_choice?(c)
            @pemk_ctx.pop_run
            pbRun(i)   # draws :r; success sets @decision (battle ends), failure eats the action
            next
          end
          next unless c.is_a?(Array)

          register_choice(i, c)
        end
        restore_mega(round[:m])
      end

      def none_choice?(c)
        !c.is_a?(Array) || c[0].nil? || c[0] == "None"
      end

      def register_choice(i, c)
        act, a1, a2, a3 = c
        case act
        when "UseMove"
          return unless a1.is_a?(Integer)

          if a1.negative?
            pbAutoChooseMove(i, false)   # Struggle round: moves[-1] would misfire
          else
            pbRegisterMove(i, a1, false)
            pbRegisterTarget(i, a3) if a3.is_a?(Integer) && a3 >= 0
          end
        when "UseItem"
          return unless a1.is_a?(String)

          pbRegisterItem(i, a1.to_sym, a2.is_a?(Integer) ? a2 : nil, a3.is_a?(Integer) && a3 >= 0 ? a3 : nil)
        when "SwitchOut"
          pbRegisterSwitch(i, a1) if a1.is_a?(Integer)
        end
        # "None" / unknown: leave the cleared choice (no action this round)
      end

      def restore_mega(m)
        return unless m.is_a?(Array)

        @megaEvolution = m.map { |side| side.is_a?(Array) ? side.dup : side }
      end

      def pbSwitchInBetween(idxBattler, _checkLaxOnly = false, _canCancel = false)
        ret = @pemk_ctx.pop_switch
        raise ReplayDivergence, "switch-in wanted for battler #{idxBattler} but record has none" if ret.nil?

        ret
      end

      def pbRun(idxBattler, duringBattle = false)
        @pemk_ctx.pop_run if duringBattle && @pemk_ctx.run_pending?(true)
        @pemk_ctx.with_run_context { super }
      end

      # `on` records: D3 adjudicated the throw server-side (zero client draws) —
      # inject the verdict: caught (4 shakes) ONLY on the FINAL recorded round of
      # a caught record (a catch always ends the battle, so the successful throw
      # is necessarily in the last round; every earlier throw was a miss —
      # review-caught: blessing EVERY throw let a multi-throw catch end rounds
      # early and false-MATCH). Shadow records ran the local calc, which draws
      # from the value-replayed :b stream — vanilla is exact there.
      def pbCaptureCalc(pkmn, _battler, catch_rate, ball)
        return super if @pemk_ctx.mode != "on"

        want = @pemk_ctx.outcome.is_a?(Hash) ? @pemk_ctx.outcome[:decision] : nil
        want == 4 && @pemk_ctx.last_round? ? 4 : 0
      end

      # The recorder digests at pbEndOfBattle ENTRY (pre-Pokérus/form-reset);
      # the replay must digest at the SAME seam or Natural-Cure-class post-battle
      # mutations systematically false-mismatch.
      def pbEndOfBattle
        @pemk_ctx.end_snapshot ||= {
          decision: @decision, turns: (turnCount rescue -1),
          player: pbParty(0).map { |p| p && { hp: p.hp, status: p.status.to_s, exp: p.exp } },
          foe:    pbParty(1).map { |p| p && { hp: p.hp, status: p.status.to_s, exp: p.exp } }
        }
        super
      end
    end

    # Battle::AI draws route to the :r stream ONLY inside pbRun (flee-vs-speed
    # roll); the AI itself never runs in replay, so any other pbAIRandom call is
    # a divergence worth failing loudly on.
    ::Battle::AI.class_eval do
      alias_method :pemk_replay_orig_pbAIRandom, :pbAIRandom
      def pbAIRandom(x)
        ctx = (@battle.respond_to?(:pemk_ctx) && @battle.pemk_ctx) || nil
        return pemk_replay_orig_pbAIRandom(x) unless ctx
        raise ReplayDivergence, "AI drew rand(#{x}) outside pbRun during replay" unless ctx.run_context?

        ctx.draw(:r, x)
      end
    end
  end
end

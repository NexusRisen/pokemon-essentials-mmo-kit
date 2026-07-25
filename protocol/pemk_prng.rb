# frozen_string_literal: true

#===============================================================================
# PEMK :: Prng — the cross-engine battle PRNG (M4 Layer D D7).
#-------------------------------------------------------------------------------
# PCG32 (XSH-RR 64/32, O'Neill) in pure Integer arithmetic with explicit 64-bit
# masking — BIT-IDENTICAL on any Ruby (MRI server, mkxp-z client) and trivially
# reimplementable in any future engine (~40 lines). Never touch Kernel#rand /
# Random here: the whole point is an RNG whose sequence is a documented contract,
# not an engine internal.
#
# This file is CANONICAL in protocol/ and vendored BYTE-IDENTICAL to
# Plugins/PEMK/001_Net/003_Prng.rb (a test asserts the two files are equal —
# edit here, copy there). It is FROZEN once D7 ships: any behavior change breaks
# every recorded battle's replayability.
#
# Streams: one 63-bit server-minted seed fans into independent substreams via
# PCG's stream-selection increment (stream_id). Fixed assignments:
#   0 = battle   (Battle#pbRandom)
#   1 = ai       (Battle::AI#pbAIRandom — live-only, never replayed)
#   2 = run      (pbRun's flee roll — drawn via pbAIRandom but replay-relevant,
#                 so it gets its own stream; see the D7 design notes)
#   3 = reserved
#===============================================================================
module PEMK
  class Prng
    M64  = (1 << 64) - 1
    M32  = (1 << 32) - 1
    MULT = 6_364_136_223_846_793_005

    STREAM_BATTLE   = 0
    STREAM_AI       = 1
    STREAM_RUN      = 2
    STREAM_RESERVED = 3

    # Draws made so far — capture-layer telemetry (desync localization).
    attr_reader :draws

    # Canonical PCG32 seeding: step, add seed, step. +stream_id+ picks the
    # increment (any two distinct ids give independent sequences).
    def initialize(seed, stream_id = 0)
      @state = 0
      @inc   = (((stream_id << 1) | 1)) & M64
      @draws = 0
      step
      @state = (@state + (seed & M64)) & M64
      step
    end

    # Next 32-bit output (PCG32 XSH-RR).
    def next_u32
      old = @state
      step
      @draws += 1
      xorshifted = (((old >> 18) ^ old) >> 27) & M32
      rot = old >> 59
      ((xorshifted >> rot) | (xorshifted << ((32 - rot) & 31))) & M32
    end

    # Unbiased integer in [0, n) via rejection sampling (no modulo bias — the
    # distribution must match Kernel#rand's fairness, not just be deterministic).
    # n <= 1 -> 0, mirroring rand(1) == 0 (callers guard non-Integer upstream).
    def rand_below(n)
      return 0 unless n.is_a?(Integer) && n > 1

      lim = (1 << 32) - ((1 << 32) % n)
      loop do
        x = next_u32
        return x % n if x < lim
      end
    end

    private

    def step
      @state = ((@state * MULT) + @inc) & M64
    end
  end
end

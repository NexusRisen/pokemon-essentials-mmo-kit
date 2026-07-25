require "minitest/autorun"
require_relative "../../protocol/pemk_prng"

# M4 Layer D D7: the cross-engine battle PRNG. The sequence IS the contract —
# these vectors are FROZEN; a change here breaks every recorded battle's
# replayability. The implementation must match the canonical PCG32 reference
# (O'Neill's pcg32_demo), not merely be self-consistent.
class PrngTest < Minitest::Test
  # O'Neill's reference demo: pcg32_srandom(42, 54) — the published first six
  # outputs. Reproducing them proves this is true PCG32 XSH-RR 64/32.
  CANONICAL = [0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e].freeze

  def test_matches_the_canonical_pcg32_reference
    r = PEMK::Prng.new(42, 54)
    assert_equal CANONICAL, 6.times.map { r.next_u32 }
  end

  def test_same_seed_same_stream_is_deterministic
    a = PEMK::Prng.new(0x1234_5678_9abc_def0, 0)
    b = PEMK::Prng.new(0x1234_5678_9abc_def0, 0)
    assert_equal 64.times.map { a.next_u32 }, 64.times.map { b.next_u32 }
  end

  def test_streams_of_one_seed_are_independent
    seed = 0x0dd_ba11
    batt = PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE)
    ai   = PEMK::Prng.new(seed, PEMK::Prng::STREAM_AI)
    run  = PEMK::Prng.new(seed, PEMK::Prng::STREAM_RUN)
    seqs = [batt, ai, run].map { |r| 32.times.map { r.next_u32 } }
    assert_equal 3, seqs.uniq.length, "streams must not collide"
  end

  def test_rand_below_bounds_and_degenerate_inputs
    r = PEMK::Prng.new(7, 0)
    1000.times do
      v = r.rand_below(100)
      assert_includes 0...100, v
    end
    assert_equal 0, r.rand_below(1)      # rand(1) == 0
    assert_equal 0, r.rand_below(0)      # degenerate -> 0 (callers guard upstream)
    assert_equal 0, r.rand_below(-5)
    assert_equal 0, r.rand_below(nil)
    assert_equal 0, r.rand_below(2.5)    # non-Integer -> 0 (hook falls back to vanilla)
  end

  def test_rand_below_is_rejection_sampled_not_modulo_biased
    # For n = 3 the unbiased limit is 2^32 - (2^32 % 3): draws at/above it are
    # rejected. Statistical smoke: counts over 30k draws stay within 2% of even.
    r = PEMK::Prng.new(99, 0)
    counts = Hash.new(0)
    30_000.times { counts[r.rand_below(3)] += 1 }
    counts.each_value { |c| assert_in_delta 10_000, c, 600 }
  end

  def test_draw_counter_counts_u32_draws
    r = PEMK::Prng.new(1, 0)
    5.times { r.next_u32 }
    assert_equal 5, r.draws
    r.rand_below(10)                     # >= 1 draw (rejection may add more)
    assert_operator r.draws, :>=, 6
  end

  def test_63_bit_seed_fits_and_masks
    max63 = (1 << 63) - 1
    r = PEMK::Prng.new(max63, 0)
    assert_kind_of Integer, r.next_u32   # no overflow surprises
    # seeds beyond 64 bits mask down (defensive; server mints 63-bit)
    a = PEMK::Prng.new((1 << 70) | 5, 0)
    b = PEMK::Prng.new(((1 << 70) | 5) & PEMK::Prng::M64, 0)
    assert_equal a.next_u32, b.next_u32
  end

  # The plugin copy is a VERBATIM vendor of the canonical protocol file — equal
  # modulo line endings (git's CRLF normalization on Windows makes raw byte
  # equality unstable across checkouts; the CODE is the contract).
  def test_plugin_copy_is_identical
    canonical = File.read(File.expand_path("../../protocol/pemk_prng.rb", __dir__)).gsub("\r\n", "\n")
    vendored  = File.read(File.expand_path("../../Plugins/PEMK/001_Net/003_Prng.rb", __dir__)).gsub("\r\n", "\n")
    assert_equal canonical, vendored,
                 "protocol/pemk_prng.rb and Plugins/PEMK/001_Net/003_Prng.rb must be identical (edit protocol/, copy to Plugins/)"
  end
end

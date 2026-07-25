require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# M4 Layer D D7 part 1 over the wire: the client's :battle_record (opaque body =
# primitive-encoded capture) lands in the battle_records corpus, seed-bound to the
# roll the server minted; duplicates for one roll are dropped (single-use as a DB
# constraint); no reply is ever sent (instrumentation).
class ServerBattleRecordTest < Minitest::Test
  W = PEMK::Wire

  FIXTURE = Tempfile.new(["pemk_world", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 2,
    "maps" => { "5" => { "name" => "Route", "width" => 20, "height" => 20,
                         "encounters" => { "0" => {
                           "Land" => { "step_chance" => 21, "slots" => [[100, "PIDGEY", 3, 5]] }
                         } } } }
  ))
  FIXTURE.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(rng: "shadow")
    env = ENV.to_h.merge("PEMK_WORLD" => FIXTURE.path,
                         "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on",
                         "PEMK_BATTLE_ENFORCE_RNG" => rng)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def open_conn; TCPSocket.new("127.0.0.1", @port); end
  def send_env(sock, env, body = nil); sock.write(W.encode_split(env, body)); end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def authed_conn(email)
    c = open_conn
    send_env(c, { type: :register, email: email, password: "password1" }); recv(c)
    send_env(c, { type: :login, email: email, password: "password1" })
    [c, recv(c)]
  end

  def mint_with_seed(c)
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    send_env(c, { type: :encounter_req, map: 5, enctype: :Land, seq: 1 })
    grant = recv(c)
    assert_equal :encounter_grant, grant[:type]
    grant
  end

  def record_env(seed: nil, mode: "shadow", outcome: 1, db: 10, da: 4, dr: 0)
    env = { type: :battle_record, mode: mode, engine_fp: "ab" * 8,
            outcome: outcome, rounds: 3,
            draws_battle: db, draws_ai: da, draws_run: dr,
            fp_battle: "0123456789abcdef", fp_ai: "fedcba9876543210", fp_run: "0" * 16,
            truncated: false, desynced: false }
    env[:battle_seed] = seed if seed
    env
  end

  def record_body
    W.encode_primitive({ v: 1, rounds: [], outcome: { decision: 1 } })
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      v = yield
      return v if v
      flunk "condition not met within #{timeout}s" if Time.now > deadline
      sleep 0.05
    end
  end

  def test_record_ingests_and_binds_to_the_minted_roll
    start_server(rng: "on")
    c, = authed_conn("br1@t.co")
    grant = mint_with_seed(c)
    seed  = grant[:battle_seed]
    assert_kind_of Integer, seed

    body = record_body
    send_env(c, record_env(seed: seed, mode: "on", outcome: 4), body)

    row = wait_for { @db[:battle_records].first }
    assert_equal "on", row[:mode]
    assert_equal seed, row[:battle_seed]
    assert_equal 4, row[:outcome]
    assert_equal body.b, row[:record].to_s.b            # stored VERBATIM
    roll_id = @db[:encounter_rolls].where(battle_seed: seed).get(:id)
    assert_equal roll_id, row[:encounter_roll_id]       # bound to the mint
    # env claims 14 draws but the body has no draw logs at all -> the walk was
    # EVADED, and that is a distinct, visible status (not "pending")
    assert_equal "no_log", row[:replay_status]
    c.close
  end

  def test_second_record_for_the_same_roll_is_dropped
    start_server(rng: "on")
    c, = authed_conn("br2@t.co")
    seed = mint_with_seed(c)[:battle_seed]

    send_env(c, record_env(seed: seed, mode: "on"), record_body)
    wait_for { @db[:battle_records].count == 1 }
    send_env(c, record_env(seed: seed, mode: "on", outcome: 2), record_body)
    wait_for { @logs.any? { |l| l.include?("duplicate record") } }
    assert_equal 1, @db[:battle_records].count          # single-use held by the DB
    c.close
  end

  def test_unknown_seed_records_unbound_and_logs
    start_server(rng: "shadow")
    c, = authed_conn("br3@t.co")
    send_env(c, record_env(seed: 12_345, mode: "shadow"), record_body)
    row = wait_for { @db[:battle_records].first }
    assert_nil row[:encounter_roll_id]
    assert(@logs.any? { |l| l.include?("unknown seed") }, @logs.inspect)
    c.close
  end

  def test_seedless_shadow_record_ingests_unbound
    start_server(rng: "shadow")
    c, = authed_conn("br4@t.co")
    send_env(c, record_env(mode: "shadow"), record_body)
    row = wait_for { @db[:battle_records].first }
    assert_nil row[:battle_seed]
    assert_nil row[:encounter_roll_id]
    c.close
  end

  def test_rng_off_ignores_records
    start_server(rng: "off")
    c, = authed_conn("br5@t.co")
    send_env(c, record_env(mode: "shadow"), record_body)
    send_env(c, { type: :ping, t: 1 }); assert_equal :pong, recv(c)[:type]
    sleep 0.2
    assert_equal 0, @db[:battle_records].count
    c.close
  end

  # --- the seed walk (the part-1 security check) --------------------------------

  # Build a packed (bound, value) log the way an HONEST on-mode client would:
  # values derived from the seed's stream.
  def honest_log(seed, stream_id, bounds)
    prng = PEMK::Prng.new(seed, stream_id)
    bounds.map { |b| [b, prng.rand_below(b)] }.flatten.pack("N*")
  end

  # FNV-1a64 over the (bound,value) pairs — must mirror the client's fold exactly.
  def fnv_of(log)
    h = 0xcbf29ce484222325
    log.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1) }
    format("%016x", h)
  end

  def walk_body(battle_log:)
    n = battle_log.bytesize / 8
    W.encode_primitive({ v: 1, truncated: false,
                         draws: { b: { n: n, fp: fnv_of(battle_log), log: battle_log },
                                  a: { n: 0, fp: "0" * 16, log: "".b },
                                  r: { n: 0, fp: "0" * 16, log: "".b } } })
  end

  def test_honest_on_record_passes_the_seed_walk
    start_server(rng: "on")
    c, = authed_conn("br7@t.co")
    seed = mint_with_seed(c)[:battle_seed]
    log  = honest_log(seed, PEMK::Prng::STREAM_BATTLE, [100, 65_536, 2, 16, 4])

    send_env(c, record_env(seed: seed, mode: "on", db: 5, da: 0), walk_body(battle_log: log))
    row = wait_for { @db[:battle_records].first }
    assert_equal "walk_ok", row[:replay_status]         # verified -> awaits part-2 replay
    refute(@logs.any? { |l| l.include?("SUSPECT rng desync") }, @logs.grep(/battlerec/).inspect)
    c.close
  end

  def test_fabricated_draws_fail_the_walk_and_flag
    start_server(rng: "on")
    c, = authed_conn("br8@t.co")
    seed = mint_with_seed(c)[:battle_seed]
    # a "lucky" fabricated log: right bounds, chosen values (all zeros = e.g. forced crits)
    log = [100, 0, 65_536, 0, 16, 0].pack("N*")

    send_env(c, record_env(seed: seed, mode: "on", db: 3, da: 0), walk_body(battle_log: log))
    row = wait_for { @db[:battle_records].first }
    assert_equal "walk_mismatch", row[:replay_status]
    assert(@logs.any? { |l| l.include?("SUSPECT rng desync") }, @logs.grep(/battlerec/).inspect)
    c.close
  end

  def test_inflated_env_counter_fails_the_walk
    start_server(rng: "on")
    c, = authed_conn("br9@t.co")
    seed = mint_with_seed(c)[:battle_seed]
    log  = honest_log(seed, PEMK::Prng::STREAM_BATTLE, [100, 100])

    # honest values but the promoted counter lies (env says 50 draws, body has 2)
    send_env(c, record_env(seed: seed, mode: "on", db: 50, da: 0), walk_body(battle_log: log))
    row = wait_for { @db[:battle_records].first }
    assert_equal "walk_mismatch", row[:replay_status]
    c.close
  end

  def test_mode_masquerade_is_marked_but_not_flagged
    start_server(rng: "on")
    c, = authed_conn("br10@t.co")
    seed = mint_with_seed(c)[:battle_seed]

    # a roll-BOUND record claiming shadow under an on server: walk dodged -> distinct
    # status + loud log, but NO desync flag (an honest pre-flip session exists)
    send_env(c, record_env(seed: seed, mode: "shadow", db: 0, da: 0), record_body)
    row = wait_for { @db[:battle_records].first }
    assert_equal "mode_mismatch", row[:replay_status]
    assert(@logs.any? { |l| l.include?("mode_mismatch") }, @logs.grep(/battlerec/).inspect)
    refute(@logs.any? { |l| l.include?("SUSPECT rng desync") })
    c.close
  end

  # --- D7 part 3: corpus retention ----------------------------------------------

  def test_prune_drops_only_old_matched_records
    a = @db[:accounts].insert(email: "prune@t.co", password_hash: "x", status: "active", created_at: Time.now)
    br  = PEMK::BattleRecords.new(@db)
    old = Time.now - (40 * 86_400)
    ins = lambda do |status, t|
      @db[:battle_records].insert(account_id: a, mode: "on", record: Sequel.blob("x"),
                                  replay_status: status, created_at: t)
    end
    ins.call("match", old)                       # spent evidence -> pruned
    ins.call("mismatch", old)                    # EVIDENCE -> kept forever
    ins.call("walk_mismatch", old)               # EVIDENCE -> kept forever
    ins.call("match", Time.now)                  # fresh match -> kept

    assert_equal 1, br.prune
    assert_equal %w[match mismatch walk_mismatch],
                 @db[:battle_records].select_map(:replay_status).sort
    assert_equal 0, br.prune(days: 0)            # 0 = retention disabled, no-op
  end

  def test_oversized_or_malformed_records_are_rejected
    start_server(rng: "shadow")
    c, = authed_conn("br6@t.co")
    send_env(c, record_env(mode: "nonsense"), record_body)          # bad mode
    send_env(c, record_env(mode: "shadow"), nil)                    # no body
    send_env(c, record_env(mode: "shadow"), "x" * (256 * 1024 + 1)) # over cap
    send_env(c, { type: :ping, t: 1 }); assert_equal :pong, recv(c)[:type]
    sleep 0.2
    assert_equal 0, @db[:battle_records].count
    c.close
  end
end

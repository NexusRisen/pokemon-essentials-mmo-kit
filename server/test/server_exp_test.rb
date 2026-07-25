require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
require "json"
require "tmpdir"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# M4 Layer D D6 part 1 over the wire: the party projection carries per-mon EXP; the
# server tracks each owned mon's high-water and logs a rollback when a later projection
# reports LESS (an old save reloaded). Detection-only.
class ServerExpTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_stats].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(exp: "shadow", rewards: nil)
    env = ENV.to_h.merge("PEMK_BATTLE_ENFORCE_EXP" => exp)
    if rewards
      env["PEMK_BATTLE_ENFORCE_REWARDS"] = rewards
      env["PEMK_BATTLE_DATA"] = synthetic_battle_data   # level-jump judging needs growth CURVES
    end
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  # A minimal battle_data.json WITH a growth curve (the repo export may predate the D4
  # curve field, which silently no-ops level-jump judging) — keeps this test self-contained.
  def synthetic_battle_data
    curve = (1..100).map { |l| l**3 }   # any strictly-increasing cumulative curve works
    doc = {
      "schema_version" => 1,
      "caps"           => { "max_level" => 100 },
      "growth_rates"   => { "Parabolic" => { "max_exp" => 1_000_000, "curve" => curve } },
      "species"        => { "PIDGEY" => { "growth_rate" => "Parabolic", "base_exp" => 50 } }
    }
    path = File.join(Dir.tmpdir, "pemk_test_battle_data_#{Process.pid}.json")
    File.write(path, JSON.generate(doc))
    path
  end

  def open_conn; TCPSocket.new("127.0.0.1", @port); end
  def send_env(sock, env); sock.write(W.encode_split(env)); end

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

  def mint_uid(c, seq:)
    send_env(c, { type: :uid_req, seq: seq, mons: [{ tmp: 4242, species: "PIDGEY", level: 5, pid: 777, egg: false }] })
    recv(c)[:grants][0][:uid]
  end

  def party(c, uid, exp, level, seq)
    send_env(c, { type: :mon_party, seq: seq, mons: [{ uid: uid, species: "PIDGEY", level: level, exp: exp }] })
    recv(c)   # :mon_ack (mailbox job — incl. observe_exp — has run by the time this returns)
  end

  def exp_log; @logs.grep(/^.*exp: /); end

  def test_high_water_tracked_and_rollback_flagged
    start_server(exp: "shadow")
    c, = authed_conn("xp1@t.co")
    uid = mint_uid(c, seq: 1)

    assert_equal :mon_ack, party(c, uid, 1_200, 7, 2)[:type]    # establishes high-water 1200
    refute(exp_log.any? { |l| l.include?("rollback") }, exp_log.inspect)

    party(c, uid, 1_800, 9, 3)                                  # legit growth — no flag
    refute(exp_log.any? { |l| l.include?("rollback") }, exp_log.inspect)

    party(c, uid, 400, 4, 4)                                    # reported EXP below high-water
    assert_equal 1, exp_log.count { |l| l.include?("SUSPECT rollback") }, exp_log.inspect
    assert(exp_log.any? { |l| l.include?("1800->400") }, exp_log.inspect)

    party(c, uid, 400, 4, 5)                                    # re-projected (crash re-login) — latched
    assert_equal 1, exp_log.count { |l| l.include?("SUSPECT rollback") }, "latch must not re-flag: #{exp_log.inspect}"

    # the server kept the high-water (1800), not the rolled-back 400
    assert_equal 1_800, @db[:monster_stats].where(uid: uid).get(:exp)
    c.close
  end

  def test_off_mode_tracks_nothing
    start_server(exp: "off")
    c, = authed_conn("xp2@t.co")
    uid = mint_uid(c, seq: 1)
    party(c, uid, 1_000, 6, 2)
    party(c, uid, 100, 3, 3)
    refute(@logs.any? { |l| l.include?("rollback") })
    assert_equal 0, @db[:monster_stats].count
    c.close
  end

  # --- D6 part 2: the :on restore plan over the wire ----------------------------

  def test_on_mode_ack_carries_up_only_corrections_until_the_restore_lands
    start_server(exp: "on")
    c, login = authed_conn("xp3@t.co")
    assert_equal "on", login[:battle_enforce_exp]               # reconcile advertises the mode
    uid = mint_uid(c, seq: 1)

    ack = party(c, uid, 1_500, 8, 2)                            # establishes high-water 1500
    assert_nil ack[:exp_correct], ack.inspect                   # clean -> no plan

    ack = party(c, uid, 600, 5, 3)                              # below high-water (old save)
    assert_equal [{ uid: uid, exp: 1_500 }], ack[:exp_correct]  # up-only restore plan

    ack = party(c, uid, 600, 5, 4)                              # not applied yet -> RE-emitted
    assert_equal [{ uid: uid, exp: 1_500 }], ack[:exp_correct]  # (client guard makes it a no-op)

    ack = party(c, uid, 1_500, 8, 5)                            # the restore landed
    assert_nil ack[:exp_correct], ack.inspect                   # self-terminating
    assert_equal 1_500, @db[:monster_stats].where(uid: uid).get(:exp)
    c.close
  end

  # The restore's own level jump must NOT trip the D4 reward audit (no battle window is
  # open, so an unexempted jump would SUSPECT-flag the server's own correction) — while a
  # jump BEYOND the restored level is still judged normally.
  def test_restore_level_jump_is_exempt_from_the_reward_audit
    start_server(exp: "on", rewards: "shadow")
    c, = authed_conn("xp5@t.co")
    uid = mint_uid(c, seq: 1)

    party(c, uid, 800, 10, 2)                                   # high-water {exp 800, lvl 10}
    ack = party(c, uid, 300, 7, 3)                              # rollback -> restore plan + exemption armed
    assert_equal [{ uid: uid, exp: 800 }], ack[:exp_correct]

    party(c, uid, 800, 10, 4)                                   # the restore lands: jump 7->10, no window
    refute(@logs.any? { |l| l.include?("SUSPECT level jump") },
           "the server flagged its own restore: #{@logs.grep(/reward:/).inspect}")

    party(c, uid, 30_000, 25, 5)                                # a REAL unbudgeted jump 10->25
    assert(@logs.any? { |l| l.include?("SUSPECT level jump") },
           "post-exemption jumps must still be judged: #{@logs.grep(/reward:/).inspect}")
    c.close
  end

  def test_shadow_mode_logs_the_plan_but_never_emits_it
    start_server(exp: "shadow")
    c, login = authed_conn("xp4@t.co")
    assert_equal "shadow", login[:battle_enforce_exp]
    uid = mint_uid(c, seq: 1)

    party(c, uid, 1_200, 7, 2)
    ack = party(c, uid, 300, 3, 3)                              # rollback
    assert_nil ack[:exp_correct], ack.inspect                   # shadow NEVER puts the plan on the wire
    assert_equal 1, exp_log.count { |l| l.include?("would restore uid#{uid}->1200") }, exp_log.inspect

    party(c, uid, 300, 3, 4)                                    # re-projected -> latched, no re-log
    assert_equal 1, exp_log.count { |l| l.include?("would restore") }, exp_log.inspect
    c.close
  end
end

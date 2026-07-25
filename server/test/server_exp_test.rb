require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
require "json"

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
    @db[:accounts].delete
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(exp: "shadow")
    env = ENV.to_h.merge("PEMK_BATTLE_ENFORCE_EXP" => exp)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
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
end

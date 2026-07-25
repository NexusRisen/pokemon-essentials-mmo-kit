require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Server relays authenticated addressed frames (challenge / battle stream) to the
# :to account only, stamping the server-trusted :from and preserving the opaque
# body (a battle team). Offline / self targets are dropped.
class ServerRoutingTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @server = PEMK::Server.new(logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def send_env(sock, env, body = nil)
    sock.write(W.encode_split(env, body))
  end

  def recv(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  def refute_receives(sock, timeout = 0.5)
    assert_raises(Timeout::Error) { recv(sock, timeout) }
  end

  def open_authed(user, pw)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: "#{user}@t.co", password: pw })
    recv(c)
    send_env(c, { type: :login, email: "#{user}@t.co", password: pw })
    [c, recv(c)[:env][:account_id]]
  end

  def test_challenge_routed_with_server_stamped_from
    a, a_id = open_authed("Chal", "passwordA1")
    b, b_id = open_authed("Ceed", "passwordB1")

    send_env(a, { type: :challenge, to: b_id, from: 12_345, name: "Chal" }) # spoofed :from ignored
    m = recv(b)
    assert_equal :challenge, m[:env][:type]
    assert_equal a_id, m[:env][:from]
    assert_equal b_id, m[:env][:to]

    a.close
    b.close
  end

  # An accepted challenge opens the peer session both payload frames require.
  def agree(a, a_id, b, b_id)
    send_env(a, { type: :challenge, to: b_id })
    recv(b)
    send_env(b, { type: :challenge_accept, to: a_id })
    recv(a)
  end

  def test_battle_team_body_preserved_within_an_agreed_session
    a, a_id = open_authed("Aaaa", "passwordA1")
    b, b_id = open_authed("Bbbb", "passwordB1")
    agree(a, a_id, b, b_id)

    body = Marshal.dump([{ species: :PIKACHU, level: 5 }])
    send_env(a, { type: :battle_team, to: b_id, name: "A" }, body)
    m = recv(b)
    assert_equal :battle_team, m[:env][:type]
    assert_equal a_id, m[:env][:from]
    assert_equal body, m[:body]

    a.close
    b.close
  end

  # --- audit: the peer channel is consent-gated -------------------------------------

  # THE zero-click Marshal.load vector: an unsolicited :battle_team used to be relayed
  # to any online account, which the client then Marshal.load'd with no consent check.
  def test_unsolicited_battle_team_is_dropped
    a, = open_authed("Evil", "passwordA1")
    b, b_id = open_authed("Vict", "passwordB1")

    send_env(a, { type: :battle_team, to: b_id }, Marshal.dump([:payload]))
    refute_receives(b)   # no session -> never reaches the victim
    a.close
    b.close
  end

  # A third party cannot inject into a live battle stream between two other accounts.
  def test_third_party_cannot_inject_into_a_battle
    a, a_id = open_authed("Play", "passwordA1")
    b, b_id = open_authed("Peer", "passwordB1")
    c, = open_authed("Trol", "passwordC1")
    agree(a, a_id, b, b_id)

    send_env(c, { type: :battle_round, to: b_id, damage: 9999 })
    refute_receives(b)
    # ...while the real partner still gets through
    send_env(a, { type: :battle_round, to: b_id, damage: 1 })
    assert_equal :battle_round, recv(b)[:env][:type]

    a.close; b.close; c.close
  end

  # An oversized relayed body used to overflow the victim's outbuf and disconnect them.
  def test_oversized_relayed_body_is_dropped
    a, a_id = open_authed("Bigg", "passwordA1")
    b, b_id = open_authed("Targ", "passwordB1")
    agree(a, a_id, b, b_id)

    send_env(a, { type: :battle_team, to: b_id }, "x" * (256 * 1024 + 1))
    refute_receives(b)
    # the victim's connection is still alive and serving
    send_env(b, { type: :ping, t: 7 })
    assert_equal :pong, recv(b)[:env][:type]

    a.close
    b.close
  end

  def test_addressed_to_offline_is_dropped
    a, = open_authed("Solo", "passwordA1")
    send_env(a, { type: :challenge, to: 999_999 }) # nobody online with that id
    refute_receives(a)
    a.close
  end
end

# frozen_string_literal: true

require_relative "test_helper"

# A response whose head has already been sent can only end one way: the
# connection closes. The relay used to have a second ending — when the
# body stalled past the idle bound, the Timeout escaped forward()'s two
# rescues (it is an IdleTimeout, not a HeadTimeout), landed in handle's
# generic IOError rescue, and rendered a whole 502 response INTO the body
# of the response already in flight. The browser got a 200 that was
# neither complete nor honest: some body, then "HTTP/1.1 502 Bad
# Gateway..." as garbage bytes, then a close. DevTools showed the 502;
# the module graph died; the page came up blank with nothing anywhere
# pointing at the real failure. Now a mid-body death is logged with the
# request that died and the connection simply closes.
class ProxyBodyRelayTest < Minitest::Test
  HEAD = 0.3
  BODY = 0.3

  def with_route(target)
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", target, 0, kind: "tcp")
    yield store
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def proxy_for(store, **opts)
    errors = []
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: BODY, head_timeout: HEAD,
      on_error: ->(msg) { errors << msg }, **opts)
    [proxy, errors]
  end

  def serve_once(proxy, server)
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end
  end

  # Answers the way the app did when this was found: head at once, a
  # first slice of body, then silence past the idle bound with the
  # connection held open.
  def stalling_backend(body_total, sent)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      sock = server.accept
      head = +""
      head << sock.gets until head =~ /\r\n\r\n\z/
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body_total}\r\n\r\n")
      sock.write("x" * sent)
      sleep BODY + 2
      sock.close rescue nil
    end
    [server, thread]
  end

  def fetch(port, path)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("GET #{path} HTTP/1.1\r\nHost: myapp.localhost\r\n\r\n")
    reader = Thread.new { sock.read }
    finished = reader.join(BODY + 5)
    flunk "client read never finished — the relay must close, not hang" unless finished
    reader.value
  ensure
    sock&.close
  end

  def test_stalled_body_closes_cleanly_instead_of_appending_a_502
    server, backend = stalling_backend(100, 5)

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy, errors = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = fetch(front.addr[1], "/big.js")

      assert response.start_with?("HTTP/1.1 200 OK\r\n"),
        "the response that was sent is the backend's, intact"
      assert_includes response, "xxxxx", "body bytes that moved stay on the wire"
      assert_equal 1, response.scan("HTTP/1.1").size,
        "exactly one response head — a 502 after a live 200 is protocol corruption"
      refute_includes response, "502"
      assert errors.any? { |m| m.include?("mid-body") && m.include?("/big.js") },
        "the stall must be logged with the request that died: #{errors.inspect}"
      assert handler.join(BODY + 5), "handler finishes on its own"
    ensure
      front&.close
    end
  ensure
    backend&.kill
    server&.close
  end

  # The guard against over-defensive fixes: a body that completes is
  # relayed whole, exactly to its Content-Length, and the connection is
  # left the way the framing says.
  def test_completing_body_still_relays_in_full
    server = TCPServer.new("127.0.0.1", 0)
    body = "y" * 64
    thread = Thread.new do
      sock = server.accept
      head = +""
      head << sock.gets until head =~ /\r\n\r\n\z/
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      sock.close
    end

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy, _errors = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = fetch(front.addr[1], "/full.js")

      assert response.start_with?("HTTP/1.1 200 OK\r\n")
      assert_includes response, body
      assert_equal 1, response.scan("HTTP/1.1").size
      refute_includes response, "502"
      assert handler.join(5)
    ensure
      front&.close
    end
  ensure
    thread&.kill
    server&.close
  end
end

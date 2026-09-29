# frozen_string_literal: true

require_relative "test_helper"

# The proxy used to block in readpartial/IO.copy_stream with no bound,
# so stale keep-alive sockets and stalled peers pinned threads until
# the proxy stopped answering. Every wait below is capped by an idle
# bound (silence, not total duration): bytes that keep moving reset
# the clock, quiet peers are dropped.
class ProxyIdleTimeoutTest < Minitest::Test
  # Short bound so the suite stays fast; production default is 60s.
  IDLE = 0.3

  def with_route(target)
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", target, 0, kind: "tcp")
    yield store
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # Both clocks get a short bound. They used to be one clock: the head
  # read rode IDLE_TIMEOUT. Now it rides its own (HEAD_TIMEOUT, 60s in
  # production), so a proxy that only shortens idle_timeout would wait the
  # full production head bound on a backend that goes quiet before its
  # first byte — and the tests below, which are all about not waiting,
  # would hang for a minute.
  def proxy_for(store, **opts)
    Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: IDLE, head_timeout: IDLE, **opts)
  end

  # One accepted connection driven through Proxy#handle, like the
  # existing live tests do.
  def serve_once(proxy, server)
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # A client that connects and then sends nothing held a handler thread
  # in readpartial forever. It must be dropped after the idle bound.
  def test_idle_client_is_dropped_after_idle_timeout
    with_route("127.0.0.1:9") do |store|
      proxy = proxy_for(store)
      server = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, server)

      sock = TCPSocket.new("127.0.0.1", server.addr[1])
      # Send nothing: the handler must give up on its own.
      assert handler.join(IDLE + 5), "handler thread must finish, not pin forever"
      refute_predicate handler, :alive?
      assert_nil sock.gets, "idle connection must be closed by the proxy"
    ensure
      sock&.close
      server&.close
    end
  end

  # A backend that accepts the request and then stops sending must not
  # pin the connection: the proxy abandons it (502) instead of waiting
  # forever. The backend here stalls 5s+ — well past the 0.3s bound —
  # so an unbounded relay would hang the client read that long.
  def test_stalled_backend_does_not_pin_connection_forever
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      head << sock.gets while head !~ /\r\n\r\n\z/
      sleep IDLE + 5 # stall mid-response: not one byte follows
      sock.close rescue nil
    end

    with_route("127.0.0.1:#{bport}") do |store|
      proxy = proxy_for(store)
      server = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, server)

      sock = TCPSocket.new("127.0.0.1", server.addr[1])
      sock.write("GET / HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: close\r\n\r\n")
      started = monotonic
      response = sock.read
      elapsed = monotonic - started

      assert_includes response, "502", "stalled backend must be abandoned with Bad Gateway"
      assert_operator elapsed, :<, IDLE + 3,
        "client must not wait out the backend's stall (took #{elapsed.round(2)}s)"
      assert handler.join(3), "handler thread must finish, not pin forever"
    ensure
      sock&.close
      server&.close
    end
  ensure
    serve&.kill
    backend&.close
  end

  # A slow trickle is legitimate long-lived traffic: 20 bytes over ~1s
  # (past the 0.3s bound in total, never quiet that long) must arrive
  # intact. This pins the idle-vs-total distinction — the bound caps
  # silence between bytes, not connection lifetime.
  def test_slow_trickling_response_is_not_killed_by_idle_timeout
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    body = "x" * 20
    serve = Thread.new do
      sock = backend.accept
      head = +""
      head << sock.gets while head !~ /\r\n\r\n\z/
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n")
      body.each_char do |ch|
        sock.write(ch)
        sleep 0.05 # trickle: ~1s total, never quiet past the bound
      end
      sock.close
    end

    with_route("127.0.0.1:#{bport}") do |store|
      proxy = proxy_for(store)
      server = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, server)

      sock = TCPSocket.new("127.0.0.1", server.addr[1])
      sock.write("GET /stream HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: close\r\n\r\n")
      response = sock.read

      assert_includes response, body,
        "a response that keeps trickling must survive past the idle bound in total"
      assert handler.join(3)
    ensure
      sock&.close
      server&.close
    end
  ensure
    serve&.join(3)
    backend&.close
  end

  # The bound is configurable per instance (tests use short values) and
  # defaults from the environment like YAMINE_MAX_CONNECTIONS does.
  # YAMINE_PROXY_IDLE_TIMEOUT is deliberately distinct from the
  # Supervisor's YAMINE_IDLE_TIMEOUT — different clock, different owner.
  def test_idle_timeout_configurable_with_env_default
    assert_kind_of Float, Yamine::Proxy::IDLE_TIMEOUT
    assert_operator Yamine::Proxy::IDLE_TIMEOUT, :>, 0

    proxy = Yamine::Proxy.new(store: nil, idle_timeout: 0.5)
    assert_equal 0.5, proxy.instance_variable_get(:@idle_timeout)
  end
end

# A per-connection accept failure must be one dropped connection, not a
# dead listener: the acceptor keeps serving while the proxy runs and
# only stops on shutdown. The failure below is a RuntimeError —
# outside the old rescue list — which used to kill the acceptor thread.
class ProxyAcceptorSurvivalTest < Minitest::Test
  # Fake listener: the first accept blows up, later accepts delegate to
  # a real TCPServer. start_foreground only needs listen/addr/accept.
  class FlakyServer
    def initialize(real)
      @real = real
      @failed = false
    end

    def listen(_port); end

    def addr
      @real.addr
    end

    def accept
      unless @failed
        @failed = true
        raise RuntimeError, "simulated accept failure"
      end

      @real.accept
    end

    def close
      @real.close
    end
  end

  def test_acceptor_serves_after_an_accept_error
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    errors = []
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: 0.3, on_error: ->(m) { errors << m })
    real = TCPServer.new("127.0.0.1", 0)
    proxy.stubs(:build_servers).returns([FlakyServer.new(real)])

    # start_foreground installs INT/TERM traps: save and restore them so
    # the suite's signal handling is untouched.
    old_int = Signal.trap("INT", -> {})
    old_term = Signal.trap("TERM", -> {})
    foreground = Thread.new { proxy.start_foreground }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 while proxy.port.zero? &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    refute_equal 0, proxy.port, "proxy must be listening"

    sock = TCPSocket.new("127.0.0.1", proxy.port)
    sock.write("GET / HTTP/1.1\r\nHost: nope.localhost\r\nConnection: close\r\n\r\n")
    response = sock.read

    assert_includes response, "503",
      "acceptor must serve the next connection after an accept error"
    assert errors.any? { |m| m.include?("accept error") },
      "unexpected accept errors must be logged, not swallowed silently"
  ensure
    sock&.close
    proxy&.stop
    # Unblock the acceptor's pending accept before joining: stop alone
    # only flips the flag when it isn't handed the servers.
    begin
      real&.close
    rescue StandardError
      nil
    end
    foreground&.join(5)
    Signal.trap("INT", old_int) if old_int
    Signal.trap("TERM", old_term) if old_term
    FileUtils.remove_entry(dir) if dir
  end
end

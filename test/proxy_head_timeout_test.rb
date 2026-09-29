# frozen_string_literal: true

require_relative "test_helper"

# The proxy drove the whole exchange off one clock: waiting for the
# backend's response head and waiting for body bytes both used
# IDLE_TIMEOUT. They had to, since the head read simply inherited it — but
# they are different questions and only one of them can be tight. The body
# half must stay generous, because a long-lived streaming response (an SSE
# chat backend) commits its head at once and then goes quiet for unbounded
# stretches with no heartbeat; killing that is worse than any slow font.
#
# The head half is now its own budget, and that is the half that decides
# whether a retry is safe: a head that ran out is proof the app is up and
# slow, which is the one failure a retry can fix without duplicating work.
class ProxyHeadTimeoutTest < Minitest::Test
  # Short bounds so the suite stays fast; production defaults are 60s for
  # both. Every wait below is a bound, not a sleep: the backends answer or
  # stall on their own schedule and the proxy gives up on its clock.
  HEAD = 0.3
  BODY = 0.3

  def with_route(target, **opts)
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", target, 0, kind: "tcp", **opts)
    yield store
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def proxy_for(store, head_timeout: HEAD, idle_timeout: BODY)
    Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: idle_timeout, head_timeout: head_timeout,
      on_error: ->(_msg) {})
  end

  # One accepted connection driven through Proxy#handle, like the existing
  # live tests do.
  def serve_once(proxy, server)
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end
  end

  # Read one request off a backend connection, body included, so a test can
  # assert what the proxy actually sent. "Never replayed" is only provable
  # by looking at the bytes the backend received.
  def read_request(sock)
    head = +""
    head << sock.gets until head =~ /\r\n\r\n\z/
    len = head[/content-length: (\d+)/i, 1].to_i
    head << sock.read(len) if len.positive?
    head
  end

  # A backend that keeps taking connections for `window` seconds and
  # records every request it reads. The accept loop has to outlive the
  # proxy's first attempt: "the backend saw this exactly once" is only
  # evidence if something was there to have seen a second one.
  def serving_backend(max: 2, window: 3)
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    thread = Thread.new do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + window
      while seen.length < max && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        next unless IO.select([server], nil, nil, 0.05)

        sock = server.accept
        seen << read_request(sock)
        yield sock, seen.length
        sock.close rescue nil
      end
    end
    [server, seen, thread]
  end

  def request(port, head, body = nil)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write(head)
    sock.write(body) if body
    sock.read
  ensure
    sock&.close
  end

  def get(port, path = "/")
    request(port, "GET #{path} HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: close\r\n\r\n")
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # The default must be the bound the head read already had, 60s. The head
  # read used to ride IDLE_TIMEOUT's default, so anything the head clock
  # does today already waits that long — a shorter default would turn a
  # request that works today into the 502 this whole change is about.
  def test_head_timeout_defaults_to_the_bound_the_head_read_already_had
    assert_kind_of Float, Yamine::Proxy::HEAD_TIMEOUT
    assert_operator Yamine::Proxy::HEAD_TIMEOUT, :>, 0
    assert_equal 60.0, Yamine::Proxy::HEAD_TIMEOUT unless ENV.key?("YAMINE_PROXY_HEAD_TIMEOUT")

    default = Yamine::Proxy.new(store: nil)
    assert_equal Yamine::Proxy::IDLE_TIMEOUT, default.instance_variable_get(:@head_timeout),
      "an unconfigured proxy must give a backend the same 60s for its head it always did"
  end

  # The two clocks answer different questions, so neither may decide the
  # other's answer. A generous body clock (streaming responses need it)
  # must not keep a head wait open: the font request that started all this
  # hung for 60s on exactly that wait.
  def test_slow_head_is_bounded_by_the_head_clock_not_the_body_clock
    server, seen, serve = serving_backend(max: 2) { |_sock, _n| sleep HEAD + 5 }

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store, head_timeout: HEAD, idle_timeout: 5)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      started = monotonic
      response = get(front.addr[1])
      elapsed = monotonic - started

      assert_includes response, "502", "a backend that never sends a head must be abandoned"
      assert_includes response, "x-yamine-error: backend-silent"
      assert_operator elapsed, :<, HEAD + 3,
        "the head clock must bound the wait, not the generous body clock (took #{elapsed.round(2)}s)"
      assert handler.join(3), "handler thread must finish, not pin forever"
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # The mirror image: a tight head clock must not shrink the body bound.
  # This is the streaming shape — head committed at once, then a trickle
  # with gaps. The gaps sit deliberately *between* the two clocks, so this
  # is the one test that catches the head budget leaking into body reads,
  # which is exactly how a tuned-for-failures proxy would kill a chat
  # stream the moment someone set YAMINE_PROXY_HEAD_TIMEOUT.
  def test_trickling_body_is_not_bounded_by_the_head_clock
    body = "x" * 3
    server, seen, serve = serving_backend(max: 1) do |sock, _n|
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n")
      body.each_char do |ch|
        sock.write(ch)
        sleep 0.5 # longer than the head bound, shorter than the body bound
      end
    end

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store, head_timeout: HEAD, idle_timeout: 2)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      started = monotonic
      response = get(front.addr[1], "/stream")
      elapsed = monotonic - started

      assert_includes response, body,
        "the head clock must not bound the body: a stream outlives it by design"
      assert_operator elapsed, :>, HEAD,
        "the stream has to actually outlast the head budget for this to prove anything"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # A GET that takes 61s to answer should serve on the second attempt
  # instead of 502ing. The head timeout is the only clock that can see
  # this: by definition nothing has come back yet, so the app is up and
  # slow rather than down.
  def test_slow_backend_is_served_after_one_retry
    server, seen, serve = serving_backend(max: 2) do |sock, n|
      if n == 1
        sleep HEAD + 0.2 # too slow for the head clock, still alive
      else
        sock.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      end
    end

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1], "/slow")

      assert_includes response, "200 OK", "a slow GET must be retried, not 502ed"
      assert_includes response, "ok"
      assert_equal 2, seen.length, "the retry must be a second real attempt at the backend"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # One retry, not a retry loop: a backend that stalls on both attempts
  # gets its 502, and exactly two requests ever reach it.
  def test_retry_happens_only_once
    server, seen, serve = serving_backend(max: 3) { |_sock, _n| sleep HEAD + 0.2 }

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1])

      assert_includes response, "502", "a backend that stalls twice must 502"
      assert_equal 2, seen.length, "one attempt plus one retry, never three"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # The retry is gated on the method, not just the body: a POST whose head
  # arrived at a slow app is a message that may already have been handled.
  # A duplicated chat message is worse than a slow page.
  def test_post_is_never_replayed
    server, seen, serve = serving_backend(max: 3) { |_sock, _n| sleep HEAD + 0.2 }

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = request(front.addr[1],
        "POST /messages HTTP/1.1\r\nHost: myapp.localhost\r\nContent-Length: 5\r\n" \
        "Connection: close\r\n\r\n", "hello")

      assert_includes response, "502", "a POST to a silent backend still gets a 502"
      assert_equal 1, seen.length, "a POST must reach the backend exactly once"
      assert_equal 1, seen.count { |head| head.start_with?("POST /messages") },
        "the one request the backend saw must be the POST, not a bodyless replay of it"
      assert_includes seen.first, "hello", "the body must not be sent twice"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # A POST with no body is still a POST: the app may act on the method
  # alone, so the bodiless-method list is the gate, not a zero length.
  def test_bodiless_post_is_still_not_replayed
    server, seen, serve = serving_backend(max: 3) { |_sock, _n| sleep HEAD + 0.2 }

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = request(front.addr[1],
        "POST /submit HTTP/1.1\r\nHost: myapp.localhost\r\nContent-Length: 0\r\n" \
        "Connection: close\r\n\r\n")

      assert_includes response, "502"
      assert_equal 1, seen.length, "only GET, HEAD and OPTIONS are safe to replay"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end
end

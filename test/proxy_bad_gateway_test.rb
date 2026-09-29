# frozen_string_literal: true

require_relative "test_helper"

# The 502 was a fixed 60 bytes — "The target app is not responding." — with
# no hostname, no target, no owner, no directory, no log and no next
# command. A dead backend and a slow one produced byte-identical pages, so
# the 60-second font request that started this came back telling nobody
# anything: not which app, not which of the two it was, not what to run.
#
# The page now answers all of those, the way render_not_found already
# answers "nobody knows what this hostname is", and carries the two failure
# classes in a header so an agent never has to parse the HTML.
class ProxyBadGatewayTest < Minitest::Test
  HEAD = 0.3
  BODY = 0.3

  # A closed port: bind one, learn its number, let it go. Racy in theory
  # (something could take it), which is the same race the OS-level refusal
  # this test needs already has.
  def dead_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def with_route(hostname, target, **opts)
    dir = Dir.mktmpdir
    app = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route(hostname, target, 0, kind: "tcp", spec: { "dir" => app },
      agent: opts.delete(:agent) || "codex")
    yield store, app
  ensure
    FileUtils.remove_entry(dir) if dir
    FileUtils.remove_entry(app) if app
  end

  def proxy_for(store, **opts)
    Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: BODY, head_timeout: HEAD, on_error: ->(_msg) {}, **opts)
  end

  def serve_once(proxy, server)
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end
  end

  def get(port, host = "myapp.localhost")
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("GET / HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
    sock.read
  ensure
    sock&.close
  end

  # Head and body in ONE write, the way a browser sends a small POST. Two
  # writes would leave the body unread in the kernel when the proxy closes
  # after a refused dial, and closing a socket with unread data resets the
  # connection instead of delivering the 502 — a pre-existing wart, not
  # something this test should be racing.
  def post(port, path, body, host = "myapp.localhost")
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("POST #{path} HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{body.bytesize}\r\n" \
               "Connection: close\r\n\r\n#{body}")
    sock.read
  ensure
    sock&.close
  end

  # A backend that takes the request and says nothing, for every attempt.
  def silent_backend(max: 3)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      taken = 0
      while taken < max && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        next unless IO.select([server], nil, nil, 0.05)

        sock = server.accept
        head = +""
        head << sock.gets until head =~ /\r\n\r\n\z/
        sleep HEAD + 0.2 # accepted the request, then nothing at all
        sock.close rescue nil
        taken += 1
      end
    end
    [server, thread]
  end

  # The two cases need opposite responses from the reader, so the page has
  # to say which one it was. An app that is up and silent gets pointed at
  # its log; an app that is not listening gets pointed at the start
  # command. Getting this backwards sends the reader to the wrong place.
  def test_silent_backend_502_names_the_app_and_says_silent
    server, serve = silent_backend

    with_route("myapp.localhost", "127.0.0.1:#{server.addr[1]}") do |store, app|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1])

      assert_includes response, "502"
      assert_includes response, "x-yamine-error: backend-silent",
        "an agent must be able to branch on the failure without reading the page"
      assert_includes response, "myapp.localhost", "the page must name the host that failed"
      assert_includes response, "127.0.0.1:#{server.addr[1]}", "and the backend it points at"
      assert_includes response,
        "The backend at <code>127.0.0.1:#{server.addr[1]}</code> accepted the connection, " \
        "then sent no response for #{HEAD} seconds"
      refute_includes response, "Nothing is listening",
        "\"silent\" and \"refused\" need different answers — do not blur them"
      assert_includes response, "codex", "the owning agent is who goes looking"
      assert_includes response, app, "the app's own directory, from the route's spec"
      refute_includes response, Dir.pwd,
        "the proxy's cwd is not the app's directory — inside a worktree that is the wrong checkout"
      assert_includes response, "#{app}/log/development.log",
        "a slow app's log is where the answer is"
      assert_includes response, "cd #{app} && yamine start",
        "the page must carry the command that fixes it"
      assert handler.join(3)
    ensure
      front&.close
    end
  ensure
    serve&.kill
    server&.close
  end

  # Nothing listening is a different page: the connection never reached an
  # app, so the answer is start it, not go read a log.
  def test_refused_dial_502_says_nothing_is_listening
    port = dead_port

    with_route("myapp.localhost", "127.0.0.1:#{port}") do |store, app|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1])

      assert_includes response, "502"
      assert_includes response, "x-yamine-error: backend-refused"
      assert_includes response, "Nothing is listening at <code>127.0.0.1:#{port}</code>."
      refute_includes response, "sent no response",
        "nothing ever arrived, so claiming a wait would send the reader to a log"
      assert_includes response, "codex"
      assert_includes response, "cd #{app} && yamine start"
      assert handler.join(3)
    ensure
      front&.close
    end
  end

  # A refused dial is the one failure where a retry is always safe: no
  # byte ever reached the app, and the request body is still unread on the
  # client socket, so a POST replays faithfully. The dial is stubbed
  # because that is the only place "did it try twice" is observable — a
  # closed port has nothing left to count connections.
  def test_refused_dial_is_retried_once_even_for_a_post
    with_route("myapp.localhost", "127.0.0.1:#{dead_port}") do |store, _app|
      proxy = proxy_for(store)
      proxy.expects(:dial).twice.raises(Errno::ECONNREFUSED, "Connection refused")
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = post(front.addr[1], "/messages", "hello")

      assert_includes response, "502"
      assert_includes response, "x-yamine-error: backend-refused"
      assert handler.join(3)
    ensure
      front&.close
    end
  end

  # Route metadata is written by other processes and interpolated into
  # HTML. An agent name or a directory is not a trusted string.
  def test_502_escapes_interpolated_route_metadata
    port = dead_port
    nasty = %{worktree/<script>alert("x")</script>}

    with_route("myapp.localhost", "127.0.0.1:#{port}", agent: nasty) do |store, _app|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1])

      refute_includes response, "<script>",
        "route metadata must be escaped before it reaches the page"
      assert_includes response, "&lt;script&gt;"
      assert handler.join(3)
    ensure
      front&.close
    end
  end

  # Same DNS-rebinding boundary render_not_found draws: a Host outside our
  # TLDs is a website that talked a browser into asking, not the local
  # developer, so it must not learn the app's directory or its owner.
  def test_502_outside_our_tlds_names_nothing
    port = dead_port

    with_route("app.example.com", "127.0.0.1:#{port}") do |store, app|
      proxy = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = serve_once(proxy, front)

      response = get(front.addr[1], "app.example.com")

      assert_includes response, "502"
      refute_includes response, app, "a foreign host must not learn the app's directory"
      refute_includes response, "codex", "a foreign host must not learn the owning agent"
      assert handler.join(3)
    ensure
      front&.close
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class ProxyControlTest < Minitest::Test
  def setup
    @state = Dir.mktmpdir
    @store = Ask::Local::RouteStore.new(@state)
  end

  def teardown
    FileUtils.remove_entry(@state)
  end

  def test_bin_path_resolves_to_real_binary
    path = Ask::Local::ProxyControl.bin_path
    assert File.file?(path), "bin_path should point at the real executable: #{path}"
    assert_match(%r{/bin/ask-local\z}, path)
    refute_match(%r{/lib/}, path)
  end

  def test_ours_false_for_foreign_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    Thread.new do
      loop do
        s = server.accept
        s.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
        s.close
      rescue StandardError
        break
      end
    end
    refute Ask::Local::ProxyControl.ours?(port, tls: false)
  ensure
    server&.close
  end

  def test_ours_true_for_ask_local_proxy
    store = @store
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    Thread.new do
      loop do
        begin
          s = server.accept
          Thread.new { proxy.send(:handle, s) }
        rescue StandardError
          break
        end
      end
    end
    sleep 0.2
    assert Ask::Local::ProxyControl.ours?(port, tls: false)
  ensure
    server&.close
  end

  def test_spawn_daemon_and_stop_end_to_end
    skip "requires spawnable ask-local binary (dev checkout)" unless File.file?(Ask::Local::ProxyControl.bin_path)

    port = Ask::Local::Ports.find_free
    pid = Ask::Local::ProxyControl.spawn_daemon(store: @store, port: port, tls: false)
    assert Ask::Local::ProxyControl.ours?(port, tls: false)
    assert_equal port, Ask::Local::ProxyControl.proxy_port(@store)
    assert_equal pid, Ask::Local::ProxyControl.read_pid(@store)

    result = Ask::Local::ProxyControl.stop(@store)
    assert_equal :stopped, result
    assert_nil Ask::Local::ProxyControl.proxy_port(@store)
  ensure
    Process.kill("TERM", pid) if pid && Ask::Local::ProxyControl.pid_alive?(pid)
  end

  def test_spawn_daemon_failure_includes_log_tail
    skip "requires spawnable ask-local binary (dev checkout)" unless File.file?(Ask::Local::ProxyControl.bin_path)

    # Occupy the port so the daemon's bind fails.
    squatter = TCPServer.new("127.0.0.1", 0)
    port = squatter.addr[1]
    error = assert_raises(Ask::Local::ProxyNotRunningError) do
      Ask::Local::ProxyControl.spawn_daemon(store: @store, port: port, tls: false)
    end
    assert_includes error.message, "proxy.log"
    assert_match(/Address already in use|EADDRINUSE/i, error.message)
  ensure
    squatter&.close
  end

  # Regression: the TLS listener handshakes inside the acceptor thread, and
  # the ours? health probe sends plain HTTP before TLS. An unhandled
  # SSL_accept error ("http request") used to kill the acceptor — and with
  # both acceptors gone the daemon exited before the readiness probe ever
  # succeeded, so spawn_daemon raised ProxyNotRunningError. A plaintext
  # connection must be one dropped connection, not a fatal crash.
  def test_tls_daemon_survives_plaintext_probe
    skip "requires spawnable ask-local binary (dev checkout)" unless File.file?(Ask::Local::ProxyControl.bin_path)

    port = Ask::Local::Ports.find_free
    pid = Ask::Local::ProxyControl.spawn_daemon(store: @store, port: port, tls: true)
    assert Ask::Local::ProxyControl.ours?(port, tls: true),
      "spawn_daemon's own plaintext-first readiness probe must not kill the TLS daemon"
    assert_equal pid, Ask::Local::ProxyControl.read_pid(@store)
  ensure
    Process.kill("TERM", pid) if pid && Ask::Local::ProxyControl.pid_alive?(pid)
  end
end

class ProxyKeepAliveTest < Minitest::Test
  # Per-request framing: two requests on one connection both get rewritten
  # headers (X-Forwarded-Proto) — the bug where only request 1 did. The
  # proxy dials a fresh backend connection per request (no pooling), so
  # the backend accepts twice.
  def test_keep_alive_rewrites_every_request
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      2.times do
        sock = backend.accept
        head = +""
        while (line = sock.gets)
          head << line
          break if head =~ /\r\n\r\n\z/
        end
        proto = head[/x-forwarded-proto:\s*(\S+)/i, 1] || "missing"
        body = "proto=#{proto}"
        sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: keep-alive\r\n\r\n#{body}")
        sock.close
      end
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET /one HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: keep-alive\r\n\r\n")
    first = read_response(sock)
    sock.write("GET /two HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: keep-alive\r\n\r\n")
    second = read_response(sock)

    assert_includes first[:body], "proto=http"
    assert_includes second[:body], "proto=http",
      "second request on a keep-alive connection must also be rewritten"
  ensure
    serve&.join(1)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_post_body_forwarded_completely
    body_seen = nil
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      head << sock.gets while head !~ /\r\n\r\n\z/
      cl = head[/content-length:\s*(\d+)/i, 1].to_i
      body = sock.read(cl)
      body_seen = body
      resp = "got #{cl}"
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{resp.bytesize}\r\nConnection: close\r\n\r\n#{resp}")
      sock.close
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    payload = "hello=world"
    sock.write("POST /form HTTP/1.1\r\nHost: myapp.localhost\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    response = sock.read
    assert_includes response, "got 11"
    assert_equal payload, body_seen
  ensure
    serve&.join(1)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_websocket_full_handshake_and_frame_echo
    require "digest/sha1"
    require "base64"
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      while (line = sock.gets)
        head << line
        break if head =~ /\r\n\r\n\z/
      end
      key = head[/sec-websocket-key:\s*(\S+)/i, 1]
      accept_key = Base64.strict_encode64(
        Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept_key}\r\n\r\n")
      # Read one masked client frame, echo payload back unmasked.
      b2 = sock.read(2).bytes[1]
      len = b2 & 0x7f
      mask = sock.read(4).bytes
      payload = sock.read(len).bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
      sock.write([0x81, payload.bytesize].pack("CC") + payload)
      sock.close
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("ws.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    key = Base64.strict_encode64("0123456789abcdef")
    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET /cable HTTP/1.1\r\nHost: ws.localhost\r\n" \
               "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    status = sock.gets
    assert_includes status, "101"
    head = +""
    while (line = sock.gets)
      head << line
      break if line == "\r\n"
    end
    expected = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    assert_includes head, expected, "backend Sec-WebSocket-Accept must survive the proxy"

    mask = [7, 7, 7, 7]
    masked = "hello".bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
    sock.write([0x81, 0x80 | 5].pack("CC") + mask.pack("C*") + masked)
    opcode = sock.read(1).ord
    out_len = sock.read(1).ord
    assert_equal 0x81, opcode
    assert_equal "hello", sock.read(out_len)
  ensure
    serve&.join(2)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_websocket_upgrade_piped_raw
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      head << sock.gets while head !~ /\r\n\r\n\z/
      sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\n\r\n")
      line = sock.gets
      sock.write("echo:#{line}")
      sock.close
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET /cable HTTP/1.1\r\nHost: myapp.localhost\r\n" \
               "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
               "Sec-WebSocket-Version: 13\r\n\r\n")
    status = sock.gets
    assert_includes status, "101"
    # Drain the rest of the 101 response head, then the tunnel is raw.
    sock.gets until (line = sock.gets) == "\r\n"
    sock.write("ping\n")
    assert_includes sock.gets, "echo:ping"
  ensure
    serve&.join(1)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end

  def read_response(sock)
    head = +""
    head << sock.gets while head !~ /\r\n\r\n\z/
    cl = head[/content-length:\s*(\d+)/i, 1].to_i
    body = sock.read(cl)
    { head: head, body: body }
  end

  def test_hop_loop_rejected_with_508
    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("loop.localhost", "127.0.0.1:9", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET / HTTP/1.1\r\nHost: loop.localhost\r\n" \
               "X-Ask-Local-Hops: 5\r\nConnection: close\r\n\r\n")
    response = sock.read
    assert_includes response, "508"
    assert_includes response, "Loop Detected"
  ensure
    sock&.close
    accept&.kill
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_chunked_response_close_delimits
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      while (line = sock.gets)
        head << line
        break if head =~ /\r\n\r\n\z/
      end
      sock.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" \
                 "Connection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
      sock.close
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET / HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: close\r\n\r\n")
    response = sock.read
    assert_includes response, "Transfer-Encoding: chunked"
    assert_includes response, "hello"
  ensure
    serve&.join(2)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end

  # Chunked REQUEST bodies (uploads without Content-Length) are streamed
  # to the backend verbatim and the connection close-delimits: correct,
  # not reusable. Pins the behavior so a future framing change can't
  # silently truncate uploads.
  def test_chunked_request_body_streamed_intact
    received = nil
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      sock = backend.accept
      head = +""
      while (line = sock.gets)
        head << line
        break if head =~ /\r\n\r\n\z/
      end
      # Read chunked body: hex-size lines until a zero chunk.
      body = +""
      loop do
        size_line = sock.gets
        break unless size_line

        size = size_line.strip.to_i(16)
        break if size.zero?

        body << sock.read(size)
        sock.gets # trailing CRLF
      end
      received = body
      resp = "got #{body.bytesize}"
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{resp.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{resp}")
      sock.close
    end

    dir = Dir.mktmpdir
    store = Ask::Local::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      loop do
        begin
          s = server.accept
          Thread.new { proxy.send(:handle, s) }
        rescue StandardError
          break
        end
      end
    end

    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("POST /upload HTTP/1.1\r\nHost: myapp.localhost\r\n" \
               "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
               "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
    sock.shutdown(Socket::SHUT_WR)
    response = sock.read
    assert_includes response, "got 11"
    assert_equal "hello world", received
  ensure
    serve&.join(2)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end
end

class ProxyTlsEndToEndTest < Minitest::Test
  # Full TLS path: SNI handshake with the local CA in the client's trust
  # store, request routed, response received — certificate verification ON.
  def test_https_request_with_sni_and_verification
    require "net/http"
    dir = Dir.mktmpdir
    state = File.join(dir, "state")
    FileUtils.mkdir_p(state)

    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve = Thread.new do
      loop do
        begin
          s = backend.accept
          head = +""
          head << s.gets while head !~ /\r\n\r\n\z/
          body = "tls-ok"
          s.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                  "Connection: close\r\n\r\n#{body}")
          s.close
        rescue StandardError
          break
        end
      end
    end

    store = Ask::Local::RouteStore.new(state)
    store.add_route("myapp.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    proxy = Ask::Local::Proxy.new(store: store, port: 0, tls: true, state_dir: state)
    raw = TCPServer.new("127.0.0.1", 0)
    port = raw.addr[1]
    ssl_server = OpenSSL::SSL::SSLServer.new(raw, Ask::Local::Certs.server_context(state))
    accept = Thread.new do
      loop do
        begin
          s = ssl_server.accept
          Thread.new { proxy.send(:handle, s) }
        rescue StandardError
          break
        end
      end
    end
    sleep 0.3

    ca_cert = OpenSSL::X509::Certificate.new(
      File.read(Ask::Local::Certs.ca_paths(state)[:cert]))
    store_ctx = OpenSSL::X509::Store.new
    store_ctx.add_cert(ca_cert)

    http = Net::HTTP.new("myapp.localhost", port)
    http.use_ssl = true
    http.cert_store = store_ctx
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = 5
    http.read_timeout = 5
    response = http.get("/")
    assert_equal "200", response.code
    assert_equal "tls-ok", response.body
  ensure
    serve&.kill
    accept&.kill
    backend&.close
    ssl_server&.close
    FileUtils.remove_entry(dir) if dir
  end
end

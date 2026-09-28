# frozen_string_literal: true

require "openssl"
require "socket"
require "uri"

module Yamine
  # Host-header reverse proxy: HTTPS on 443 (or HTTP on 80 with --no-tls)
  # routing to unix-socket or TCP backends from the RouteStore.
  #
  # Pure stdlib: TCPServer + threads. HTTP/1.1 framing is honored
  # per-request so keep-alive connections get header rewriting
  # (X-Forwarded-*) on every request, not just the first; Upgrade
  # requests (ActionCable) fall back to raw byte piping. Chunked or
  # unclassifiable responses are close-delimited (connection not
  # reused). Deliberately HTTP/1.1 only for v1.
  class Proxy
    HOPS_HEADER = "x-yamine-hops"
    HEALTH_HEADER = "x-yamine"
    MAX_HOPS = 5
    MAX_HEAD_BYTES = 64 * 1024
    MAX_HOSTNAME_BYTES = 253
    # Bounded concurrency: beyond this many simultaneous connections the
    # proxy answers 503 instead of spawning threads without limit.
    MAX_CONNECTIONS = Integer(ENV.fetch("YAMINE_MAX_CONNECTIONS", "200"))
    # Idle bound: waiting for the NEXT byte on any client or backend
    # socket gives up after this many seconds. The clock resets on every
    # byte transferred, so it caps silence — never total duration. A
    # slow trickle (SSE/NDJSON chat stream, big download) runs as long as
    # bytes keep moving; a peer that goes quiet is dropped instead of
    # pinning a thread. Without this, stale keep-alive sockets and
    # stalled peers accumulate until the proxy stops answering.
    # Named YAMINE_PROXY_IDLE_TIMEOUT (not YAMINE_IDLE_TIMEOUT — that one
    # is the Supervisor's app-idle kill, a different clock entirely).
    IDLE_TIMEOUT = Float(ENV.fetch("YAMINE_PROXY_IDLE_TIMEOUT", "60"))
    # Raised when a peer is silent past the idle bound. An IOError so the
    # existing rescue-and-close paths treat it like any dead peer.
    IdleTimeout = Class.new(IOError)
    CHUNK_BYTES = 16_384
    # Route cache: routes.json is the source of truth, but re-reading
    # and re-parsing it on every request is wasteful under HMR polling.
    # Keyed on file mtime, so a freshly registered route is visible on
    # the very next request (no TTL race for agents that boot then curl).

    NotFound = Struct.new(:host, :routes)
    BadGateway = Struct.new(:host, :detail)
    LoopDetected = Struct.new(:host, :hops)

    def initialize(store:, port: 443, tls: true, state_dir: nil, on_error: nil,
      supervisor: nil, max_connections: MAX_CONNECTIONS, idle_timeout: IDLE_TIMEOUT, tlds: nil)
      @store = store
      @port = port
      @tls = tls
      @state_dir = state_dir || Certs.state_dir
      @on_error = on_error || ->(msg) { warn msg }
      @supervisor = supervisor
      @max_connections = max_connections
      @idle_timeout = idle_timeout
      @tlds = Array(tlds).flatten.compact.map(&:downcase)
      @tlds = [Hostname::DEFAULT_TLD] if @tlds.empty?
      @inflight = 0
      @inflight_mutex = Mutex.new
      @route_cache = nil
      @route_cache_mtime = nil
      @route_cache_mutex = Mutex.new
      @running = false
    end

    attr_reader :port, :supervisor, :tlds

    def tls?
      @tls
    end

    def start_foreground
      @running = true
      servers = build_servers
      servers.each { |s| s.listen(@port) }
      @port = servers.first.addr[1]
      Ownership.chown_state_dir(@store.dir)
      ensure_system_ca_trust if Process.uid.zero?
      trap("INT") { stop(servers) }
      trap("TERM") do
        @supervisor&.shutdown
        stop(servers)
      end
      acceptors = servers.map do |server|
        Thread.new do
          while @running
            begin
              sock = server.accept
              unless admit?
                begin
                  sock.write("HTTP/1.1 503 Service Unavailable\r\n" \
                             "Content-Length: 0\r\nConnection: close\r\n\r\n")
                rescue StandardError
                  nil
                end
                sock.close rescue nil
                next
              end
              Thread.new do
                begin
                  handle(sock)
                ensure
                  release
                end
              end
            rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
              # A per-connection accept failure (bad TLS handshake,
              # reset peer) is one dropped connection, not a reason to
              # stop listening. Only shutdown breaks the loop.
              next if @running
              break
            rescue StandardError => e
              # An unexpected accept error must not silently kill the
              # acceptor either: log it and keep serving while running.
              @on_error.call("accept error: #{e.class}: #{e.message}")
              next if @running
              break
            end
          end
        end
      end
      acceptors.each(&:join)
    end

    def stop(servers = nil)
      @running = false
      Array(servers).each { |s| s.close rescue nil }
    end

    # Pure request-routing core, tested without sockets.
    #
    # Exact hostname first, then an opted-in wildcard. The wildcard is
    # deliberately not ambient: a route only answers its own subdomains
    # when it registered with `subdomains: true` (config
    # `proxy.subdomains`, or `yamine alias --wildcard`).
    #
    # It used to be unconditional, which meant every unregistered label
    # under any live app silently resolved to that app. The expensive
    # case is a worktree: `<branch>.myapp.localhost` answered as the main
    # checkout — a wrong-but-working app, indistinguishable from the
    # right one. An unregistered hostname now 404s, and says so.
    def route(authority, routes)
      host = Hostname.strip_port(authority)
      return nil if host.empty? || host.bytesize > MAX_HOSTNAME_BYTES

      exact = routes.find { |r| r["hostname"] == host }
      return exact if exact

      routes.find { |r| r["subdomains"] && host.end_with?(".#{r["hostname"]}") }
    end

    def check_hops(headers)
      hops = headers[HOPS_HEADER].to_i
      hops >= MAX_HOPS ? hops : nil
    end

    private

    # A root proxy (launchd service or sudo daemon) is the one process
    # that can trust the CA into the System keychain silently — no GUI
    # popup. Idempotent: the state-dir marker makes repeat boots a no-op.
    def ensure_system_ca_trust
      return if Certs.trusted?(@state_dir)

      result = Trust.trust(@state_dir)
      @on_error.call("CA trust warning: #{result[:error]}") unless result[:trusted]
    end

    def admit?
      @inflight_mutex.synchronize do
        return false if @inflight >= @max_connections

        @inflight += 1
        true
      end
    end

    def release
      @inflight_mutex.synchronize { @inflight -= 1 if @inflight.positive? }
    end

    def cached_routes
      @route_cache_mutex.synchronize do
        mtime = routes_mtime
        if @route_cache.nil? || mtime != @route_cache_mtime
          @route_cache = @store.load_routes
          @route_cache_mtime = mtime
        end
        @route_cache
      end
    end

    def routes_mtime
      File.mtime(@store.routes_path)
    rescue SystemCallError
      nil
    end

    # Both IPv4 and IPv6 loopback: *.localhost often resolves to ::1
    # first, and binding v4-only then refuses with no helpful message.
    def build_servers
      [TCPServer.new("127.0.0.1", @port), TCPServer.new("::1", @port)].map do |server|
        next server unless @tls

        with_deferred_handshake(OpenSSL::SSL::SSLServer.new(server, Certs.server_context(@state_dir)))
      end
    rescue SystemCallError
      server = TCPServer.new("127.0.0.1", @port)
      @tls ? [with_deferred_handshake(OpenSSL::SSL::SSLServer.new(server, Certs.server_context(@state_dir)))] : [server]
    end

    # The TLS handshake reads from the peer, so doing it inside
    # SSLServer#accept would let a connect-and-send-nothing client pin an
    # acceptor thread forever (and with both acceptors pinned the proxy
    # stops answering). Defer it: accept returns after the TCP handshake
    # and the per-connection thread finishes TLS under the idle bound in
    # #handle. SNI/cert behavior is unchanged — only the timing moves.
    def with_deferred_handshake(ssl_server)
      ssl_server.start_immediately = false
      ssl_server
    end

    # One connection = many requests (keep-alive). Each request head is
    # re-parsed and rewritten; bodies are framed by Content-Length;
    # responses with Content-Length allow the loop to continue.
    def handle(sock)
      tls_handshake(sock)
      buf = +""
      loop do
        head, buf = read_head(sock, buf)
        break if head.nil? || head.empty?

        method, target, headers = parse_head(head)
        host = headers["host"].to_s

        if upgrade_request?(headers)
          handle_upgrade(sock, head, buf)
          break
        end

        routes = cached_routes
        entry = route(host, routes)
        if entry.nil?
          render_not_found(sock, host, routes)
          break
        end

        if check_hops(headers)
          render_loop(sock, Hostname.strip_port(host))
          break
        end

        # Supervised managed apps may be stopped (idle/crashed/restarted):
        # boot on request, then serve.
        if @supervisor && entry["kind"] == "socket" && entry["spec"]
          entry = @supervisor.ensure_running(entry)
          unless entry
            render_bad_gateway(sock)
            break
          end
        end
        @supervisor&.touch(entry["hostname"])

        headers[HOPS_HEADER] = (headers[HOPS_HEADER].to_i + 1).to_s
        set_forwarded(headers, sock, tls: @tls)

        begin
          backend = dial(entry)
        rescue SystemCallError => e
          @on_error.call("dial failed for #{host}: #{e.message}")
          render_bad_gateway(sock)
          break
        end

        keep = pipe_request(sock, backend, method, target, headers, buf)
        unless keep == :keep_alive
          backend.close rescue nil
          break
        end
        backend.close rescue nil
      end
    rescue SystemCallError, OpenSSL::SSL::SSLError, IOError => e
      @on_error.call("Proxy error: #{e.message}")
      render_bad_gateway(sock) rescue nil
    ensure
      sock.close rescue nil
    end

    # Forward one request (body framed by Content-Length), then relay
    # the response. Returns :keep_alive when both sides want to reuse
    # the connection and the response length was known.
    def pipe_request(sock, backend, method, target, headers, buf)
      write_all(backend, rebuild_head(method, target, headers))

      body_len = request_body_length(headers)
      if body_len == :chunked
        # Unclassifiable request body: stream to EOF, close after.
        write_all(backend, buf) unless buf.empty?
        copy_stream(sock, backend)
        relay_response_close(backend, sock)
        return :close
      end

      remaining = body_len
      unless buf.empty?
        from_buf = buf.byteslice(0, remaining)
        write_all(backend, from_buf)
        remaining -= from_buf.bytesize
        buf = buf.byteslice(from_buf.bytesize..) || +""
      end
      copy_stream(sock, backend, remaining) if remaining > 0

      rhead, rbuf = read_head(backend, +"")
      if rhead.nil?
        render_bad_gateway(sock)
        return :close
      end
      _rm, _rt, rheaders = parse_head(rhead)
      write_all(sock, rhead)
      write_all(sock, rbuf) unless rbuf.empty?

      rlen = content_length(rheaders)
      if rlen.nil?
        # No Content-Length: close-delimited response.
        copy_stream(backend, sock)
        return :close
      end
      remaining = rlen - rbuf.bytesize
      copy_stream(backend, sock, remaining) if remaining > 0

      if keep_alive?(headers) && keep_alive?(rheaders)
        # Any bytes beyond Content-Length on the backend are a second
        # pipelined response on a connection we won't reuse — drop.
        :keep_alive
      else
        :close
      end
    end

    def relay_response_close(backend, sock)
      rhead, rbuf = read_head(backend, +"")
      return if rhead.nil?

      write_all(sock, rhead)
      write_all(sock, rbuf) unless rbuf.empty?
      copy_stream(backend, sock)
    rescue IOError, SystemCallError
      nil
    end

    def handle_upgrade(sock, head, buf)
      routes = cached_routes
      method, target, headers = parse_head(head)
      entry = route(headers["host"].to_s, routes)
      return unless entry

      # Upgrades carry the same forwarded headers as every other request:
      # an app behind the proxy (ActionCable's origin check) reads the
      # scheme from X-Forwarded-Proto, and a verbatim head would tell a
      # wss:// connection it arrived as http.
      set_forwarded(headers, sock, tls: @tls)

      backend = dial(entry)
      write_all(backend, rebuild_head(method, target, headers))
      write_all(backend, buf) unless buf.empty?
      pipe_both(sock, backend)
    rescue SystemCallError, OpenSSL::SSL::SSLError, IOError => e
      @on_error.call("upgrade proxy error: #{e.message}")
    ensure
      backend&.close rescue nil
      sock.close rescue nil
    end

    def upgrade_request?(headers)
      headers["upgrade"] && headers["connection"].to_s.downcase.include?("upgrade")
    end

    def request_body_length(headers)
      if headers["content-length"]
        Integer(headers["content-length"])
      elsif headers["transfer-encoding"].to_s.downcase.include?("chunked")
        :chunked
      else
        0
      end
    rescue ArgumentError
      :chunked
    end

    def content_length(headers)
      headers["content-length"] && Integer(headers["content-length"])
    rescue ArgumentError
      nil
    end

    def keep_alive?(headers)
      return false if headers["connection"].to_s.downcase.include?("close")

      true
    end

    # Read just the header block without stdio buffering (so nothing is
    # stolen from the body stream). `buf` carries bytes read ahead
    # (pipelined requests) across calls. Returns [head, buf]. The wait
    # for more bytes is idle-bounded: a peer that sends nothing is
    # dropped (nil) instead of pinning the thread.
    def read_head(sock, buf)
      loop do
        if (idx = buf.index("\r\n\r\n"))
          return [buf.byteslice(0, idx + 4), buf.byteslice(idx + 4..) || +""]
        end
        return [nil, buf] if buf.bytesize > MAX_HEAD_BYTES

        buf << read_chunk(sock, CHUNK_BYTES)
      end
    rescue EOFError, IOError
      [nil, +""]
    end

    # Finish a deferred TLS handshake under the idle bound. A no-op for
    # plain sockets and for SSLSockets that already handshook (a second
    # accept on an established connection returns immediately).
    def tls_handshake(sock)
      return unless sock.is_a?(OpenSSL::SSL::SSLSocket)

      loop do
        result = sock.accept_nonblock(exception: false)
        return if result.is_a?(OpenSSL::SSL::SSLSocket)

        wait_for(sock, result)
      end
    end

    # One idle-bounded read: returns bytes, raises EOFError at end of
    # stream, IdleTimeout when the peer is silent past the bound. Never
    # blocks in the kernel without a select deadline, so no stalled peer
    # pins the thread — including mid-TLS-handshake stalls, which plain
    # readpartial would ride out forever.
    def read_chunk(sock, size)
      loop do
        result = sock.read_nonblock(size, exception: false)
        return result if result.is_a?(String)
        raise EOFError, "end of file reached" if result.nil?

        wait_for(sock, result)
      end
    end

    # Idle-bounded write of the whole string. A peer that stops reading
    # (full window) stalls here only until the bound, then IdleTimeout.
    def write_all(sock, data)
      offset = 0
      while offset < data.bytesize
        result = sock.write_nonblock(data.byteslice(offset..), exception: false)
        if result.is_a?(Integer)
          # A zero write made no progress: wait like a blocked writer
          # instead of spinning.
          result.zero? ? wait_for(sock, :wait_writable) : offset += result
        else
          wait_for(sock, result)
        end
      end
      offset
    end

    # Idle-bounded relay. length nil copies to EOF (close-delimited or
    # chunked-upload bodies); otherwise exactly length bytes. Every byte
    # that moves resets the idle clock, so a slow trickle survives while
    # a stalled source is abandoned with IdleTimeout. A truncated fixed
    # body re-raises EOFError like IO.copy_stream did.
    def copy_stream(src, dst, length = nil)
      remaining = length
      loop do
        break if !remaining.nil? && remaining <= 0

        size = remaining.nil? ? CHUNK_BYTES : [CHUNK_BYTES, remaining].min
        begin
          data = read_chunk(src, size)
        rescue EOFError
          raise if !remaining.nil? && remaining.positive?

          break
        end
        write_all(dst, data)
        remaining -= data.bytesize unless remaining.nil?
      end
    end

    # Block until the socket is ready for the direction a nonblocking op
    # asked for; IdleTimeout when the bound passes with no progress.
    def wait_for(sock, wait_kind)
      if wait_kind == :wait_readable
        raise IdleTimeout, "idle timeout after #{@idle_timeout}s with no bytes" unless readable?(sock)
      elsif !writable?(sock)
        raise IdleTimeout, "idle timeout after #{@idle_timeout}s with no bytes"
      end
      nil
    end

    # select(2) with the idle bound. SSL-buffered bytes count as
    # readable without a syscall. A closed socket raises in select —
    # report not-ready and let the nonblocking op raise the real error.
    def readable?(sock)
      return true if sock.respond_to?(:pending) && sock.pending.positive?

      !IO.select([sock], nil, nil, @idle_timeout).nil?
    rescue IOError, SystemCallError
      false
    end

    def writable?(sock)
      !IO.select(nil, [sock], nil, @idle_timeout).nil?
    rescue IOError, SystemCallError
      false
    end

    def parse_head(head)
      lines = head.split("\r\n")
      method, target, _version = lines.first.to_s.split(" ", 3)
      headers = {}
      lines[1..].each do |line|
        break if line.empty?

        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if key && value
      end
      [method, target, headers]
    end

    # X-Forwarded-* trust boundary: the proxy only ever listens on
    # loopback, so a client-supplied X-Forwarded-For is the local
    # developer's own header, not an attacker-controlled spoof. Never
    # bind this proxy to a non-loopback interface without rethinking
    # this (and Host-based routing) first.
    def set_forwarded(headers, sock, tls:)
      addr = begin
        sock.peeraddr[3]
      rescue StandardError
        "127.0.0.1"
      end
      headers["x-forwarded-for"] = [headers["x-forwarded-for"], addr].compact.join(", ")
      headers["x-forwarded-proto"] = tls ? "https" : "http"
      headers["x-forwarded-host"] ||= headers["host"].to_s
    end

    def dial(entry)
      case entry["kind"]
      when "socket"
        UNIXSocket.new(entry["target"])
      else
        host, port = entry["target"].split(":", 2)
        TCPSocket.new(host, port.to_i)
      end
    end

    def rebuild_head(method, target, headers)
      lines = ["#{method} #{target} HTTP/1.1"]
      headers.each { |k, v| lines << "#{k}: #{v}" }
      (lines.join("\r\n") + "\r\n\r\n")
    end

    # Raw bidirectional pump for upgrades; either side closing unblocks
    # the other. Deliberately outside the idle bound: an idle websocket
    # is legitimate traffic (silence is the normal state), and framing
    # no longer applies once the connection is hijacked.
    #
    # Whichever direction reaches EOF first tears down BOTH ends, and it
    # has to do that with shutdown before close. The sibling copy is
    # parked in a blocking read on the socket being torn down, and a
    # close from another thread does not interrupt that read on linux (it
    # does on macOS) — so close-only left the parked copy alive forever
    # and `t1.join` never returned: one leaked thread per closed upgrade,
    # plus a `handle` that never unwound, in the root daemon. shutdown(2)
    # changes the socket's kernel state instead of dropping the fd, so
    # the parked read comes back with EOF at once — deterministic, and
    # with no timeout added to a path that must stay unbounded.
    def pipe_both(client, backend)
      t1 = Thread.new do
        IO.copy_stream(client, backend)
      rescue IOError, SystemCallError
        nil
      ensure
        teardown_half(backend)
      end
      t2 = Thread.new do
        IO.copy_stream(backend, client)
      rescue IOError, SystemCallError
        nil
      ensure
        teardown_half(client)
      end
      t1.join
      t2.join
    end

    # End one end of a hijacked connection: unblock the sibling copy
    # first, then close. Runs from an ensure, so it swallows everything
    # — an exception escaping here would unwind into the acceptor.
    def teardown_half(sock)
      # An SSLSocket (the TLS client's socket) has no #shutdown; its
      # kernel socket is one level down, and that is the fd the parked
      # read is sitting on.
      io = sock.respond_to?(:shutdown) ? sock : sock.to_io
      io.shutdown(Socket::SHUT_RDWR)
    rescue StandardError
      nil
    ensure
      sock.close rescue nil
    end

    # DNS-rebinding boundary: the proxy binds loopback, so any website
    # that tricks a browser into requesting 127.0.0.1 reaches us. A
    # foreign Host (outside our TLDs) gets a bare 404 that names nothing —
    # never the route list. Only requests under our own TLDs see the
    # helpful "no app registered, here are your apps" page, where the
    # requester is unambiguously the local developer.
    def friendly_host?(host)
      @tlds.any? { |tld| host == tld || host.end_with?(".#{tld}") }
    end

    def render_not_found(sock, host, routes)
      bare = Hostname.strip_port(host)
      unless friendly_host?(bare.downcase)
        return respond(sock, 404, "<h1>Not Found</h1>")
      end

      # A label in front of a live app is almost always a worktree or a
      # branch whose stack is not running. Name the parent it would fall
      # under and where it lives, so "the app loaded but it's the wrong
      # code" becomes "that worktree isn't running" without a search.
      parent = routes.find { |r| bare.end_with?(".#{r["hostname"]}") }
      hint = if parent
        dir = parent.dig("spec", "dir")
        where = dir ? " in #{escape(dir)}" : ""
        "<p><strong>#{escape(parent["hostname"])}</strong> is running#{where}.</p>" \
          "<p>If #{escape(bare)} is a worktree or branch, start it there " \
          "(<code>yamine start</code>), or open " \
          "<strong>#{escape(parent["hostname"])}</strong> instead.</p>"
      end

      items = routes.map { |r| "<li>#{escape(r["hostname"])}</li>" }.join
      body = "<h1>No app registered for #{escape(bare)}</h1>" \
             "#{hint}<ul>#{items}</ul>"
      # 503, not 404: 404 says the app answered and has nothing at that path,
      # and a client that believes it goes looking for a bug in the app. This
      # is the proxy saying the app is not there — the same answer a dead
      # backend gets (502 Bad Gateway), so no caller has to read the body to
      # tell "not running" from "the app said no".
      respond(sock, 503, body)
    end

    def render_bad_gateway(sock)
      respond(sock, 502, "<h1>Bad Gateway</h1><p>The target app is not responding.</p>")
    rescue IOError, SystemCallError
      nil
    end

    def render_loop(sock, host)
      respond(sock, 508, "<h1>Loop Detected</h1><p>#{escape(host)} passed through " \
                         "yamine too many times. Check dev-server proxy config.</p>")
    rescue IOError, SystemCallError
      nil
    end

    def respond(sock, status, body)
      message = { 404 => "Not Found", 502 => "Bad Gateway", 508 => "Loop Detected" }[status]
      write_all(sock, "HTTP/1.1 #{status} #{message}\r\n" \
                      "Content-Type: text/html\r\n" \
                      "#{HEALTH_HEADER}: 1\r\n" \
                      "Content-Length: #{body.bytesize}\r\n" \
                      "Connection: close\r\n\r\n#{body}")
    rescue IOError, SystemCallError
      nil
    end

    def escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end

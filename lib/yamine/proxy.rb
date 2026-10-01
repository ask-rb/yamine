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
    # Failure class on a 502 (backend-refused / backend-silent), so an
    # agent can branch on what went wrong without parsing the page. Same
    # split of labour as HEALTH_HEADER: a browser shows the human the body,
    # an agent reads the header.
    ERROR_HEADER = "x-yamine-error"
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
    # Head bound: how long a backend gets to send the response *head*
    # after the request is fully forwarded. Split from IDLE_TIMEOUT
    # because the two answer different questions, and answering them with
    # one clock is what made a dead backend and a slow one look identical.
    #
    # IDLE_TIMEOUT caps silence between *body* bytes, so it has to stay
    # generous: a long-lived streaming response (an SSE chat backend)
    # commits its head at once and then goes quiet for unbounded stretches
    # with no heartbeat, and any clock that bounds its life is wrong. The
    # head is the backend's first chance to say anything at all, and until
    # it does the client has nothing to stream — a font that hangs 60s and
    # then 502s tells neither a human nor an agent why.
    #
    # Defaults to the same 60s the head read already got (it used to ride
    # IDLE_TIMEOUT's default), so splitting the clocks cannot turn a
    # request that works today into a failure.
    HEAD_TIMEOUT = Float(ENV.fetch("YAMINE_PROXY_HEAD_TIMEOUT", "60"))
    # Raised when a response head runs out its own budget. A distinct class
    # because the two timeouts mean different things: HeadTimeout is the
    # one backend failure where the app is provably up and merely slow,
    # which is also the only one a retry can be safe for.
    HeadTimeout = Class.new(IdleTimeout)
    CHUNK_BYTES = 16_384
    CRLF = "\r\n"
    # Route cache: routes.json is the source of truth, but re-reading
    # and re-parsing it on every request is wasteful under HMR polling.
    # Keyed on file mtime, so a freshly registered route is visible on
    # the very next request (no TTL race for agents that boot then curl).

    NotFound = Struct.new(:host, :routes)
    BadGateway = Struct.new(:host, :detail)
    LoopDetected = Struct.new(:host, :hops)

    def initialize(store:, port: 443, tls: true, state_dir: nil, on_error: nil,
      supervisor: nil, max_connections: MAX_CONNECTIONS, idle_timeout: IDLE_TIMEOUT,
      head_timeout: HEAD_TIMEOUT, tlds: nil)
      @store = store
      @port = port
      @tls = tls
      @state_dir = state_dir || Certs.state_dir
      @on_error = on_error || ->(msg) { warn msg }
      @supervisor = supervisor
      @max_connections = max_connections
      @idle_timeout = idle_timeout
      @head_timeout = head_timeout
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
      ensure_ca_trust
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

    # The proxy is the process the browser's TLS stack actually talks to,
    # so it is where the CA has to be trusted — as root, into the System
    # keychain silently, and as a normal user, into the login keychain.
    # A non-elevated proxy used to skip this entirely, which is how a
    # first run as an ordinary user installed a CA that could not work.
    #
    # `Trust.trusted?` asks the trust store, not just the state-dir
    # marker, so a CA that is present but untrusted is repaired instead
    # of being short-circuited. Trust.trust only writes the marker once
    # the trust setting is confirmed, so a failure is retried (and
    # reported) on the next boot rather than cached as a success.
    #
    # YAMINE_SKIP_CA_TRUST is for machines whose CA arrives some other
    # way — an MDM profile, a hand-run `security add-trusted-cert` — and
    # for the suite, which spawns real proxies and must never reach a real
    # keychain.
    def ensure_ca_trust
      return if ENV["YAMINE_SKIP_CA_TRUST"]
      return if Trust.trusted?(@state_dir)

      result = Trust.trust(@state_dir)
      return if result[:trusted]

      @on_error.call("CA trust warning: #{result[:error]}")
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
      # The 502 below names the app, so it needs the route it was serving
      # and the host that asked for it. A connection can fail before
      # either exists (a client that connects and stalls), so both start
      # out empty and the page degrades instead of naming a wrong app.
      entry = nil
      host = ""
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
          booted = @supervisor.ensure_running(entry)
          unless booted
            render_bad_gateway(sock, entry, host, :refused)
            break
          end
          entry = booted
        end
        @supervisor&.touch(entry["hostname"])

        headers[HOPS_HEADER] = (headers[HOPS_HEADER].to_i + 1).to_s
        set_forwarded(headers, sock, tls: @tls)

        keep, reason = forward(sock, entry, method, target, headers, buf)
        # One retry, and only where retrying cannot duplicate work. A
        # backend that was merely slow answers the second attempt; a POST
        # that arrived twice is worse than a slow page, so a bodiless
        # request is the only one that gets another chance.
        if reason && retriable?(reason, method, headers)
          @on_error.call("retrying #{method} #{host} after #{reason}")
          keep, reason = forward(sock, entry, method, target, headers, buf)
        end

        if reason == :body_lost
          # The response head already reached the client; there is no
          # answer left to give, only a connection to close. A 502 here
          # would be garbage appended to a live response.
          break
        end

        if reason
          render_bad_gateway(sock, entry, host, reason)
          break
        end
        break unless keep == :keep_alive
      end
    rescue SystemCallError, OpenSSL::SSL::SSLError, IOError => e
      @on_error.call("Proxy error: #{e.message}")
      render_bad_gateway(sock, entry, host, :gone) rescue nil
    ensure
      sock.close rescue nil
    end

    # One attempt at the backend: dial, forward the request, relay the
    # response. Returns [keep_alive?, reason], where reason is nil on
    # success and otherwise names which failure this was. That one
    # value decides both whether a retry is safe and what the 502 says, so
    # "refused" and "silent" can never drift apart again.
    #
    # The backend socket is always closed here: it is never reused (only
    # the client connection is), so a failed attempt has nothing to keep
    # alive either.
    def forward(sock, entry, method, target, headers, buf)
      begin
        backend = dial(entry)
      rescue SystemCallError => e
        @on_error.call("dial failed for #{entry["hostname"]}: #{e.class}: #{e.message}")
        return [:close, failure_reason(e)]
      end

      begin
        pipe_request(sock, backend, method, target, headers, buf)
      rescue HeadTimeout
        [:close, :silent]
      rescue EOFError
        [:close, :gone]
      ensure
        backend.close rescue nil
      end
    end

    # What a failed dial means. ECONNREFUSED is the one failure that
    # indicts the backend; the rest indict the path or the proxy itself,
    # and reporting them as "Nothing is listening" sends the reader off to
    # restart an app that is perfectly fine — an fd-exhausted proxy spent
    # one whole debugging evening dressed as a dead backend.
    def failure_reason(error)
      case error
      when Errno::ECONNREFUSED then :refused
      when Errno::EMFILE, Errno::ENFILE then :exhausted
      else :unreachable
      end
    end

    # A refused dial never reached the app, so any method replays safely —
    # the request body is still unread on the client socket. A head
    # timeout or an exhausted proxy means the attempt died on our side of
    # the wire, so the only safe replays are the bodiless methods: the
    # body has already been consumed off the client socket and cannot be
    # faithfully resent, and a duplicated message is a worse outcome than
    # a slow page.
    def retriable?(reason, method, headers)
      return true if reason == :refused
      return false unless [:silent, :exhausted].include?(reason)
      return false unless %w[GET HEAD OPTIONS].include?(method.to_s.upcase)

      request_body_length(headers) == 0
    end

    # Forward one request (body framed by Content-Length), then relay
    # the response. Returns [keep_alive?, reason]: :keep_alive when both
    # sides want to reuse the connection and the response length was
    # known, and a reason when the backend failed to answer instead.
    def pipe_request(sock, backend, method, target, headers, buf)
      write_all(backend, rebuild_head(method, target, headers))

      body_len = request_body_length(headers)
      if body_len == :chunked
        # Unclassifiable request body: stream to EOF, close after.
        write_all(backend, buf) unless buf.empty?
        copy_stream(sock, backend)
        relay_response_close(backend, sock)
        return [:close, nil]
      end

      remaining = body_len
      unless buf.empty?
        from_buf = buf.byteslice(0, remaining)
        write_all(backend, from_buf)
        remaining -= from_buf.bytesize
        buf = buf.byteslice(from_buf.bytesize..) || +""
      end
      copy_stream(sock, backend, remaining) if remaining > 0

      rhead, rbuf = read_response_head(backend)
      return [:close, :gone] if rhead.nil?

      _rm, _rt, rheaders = parse_head(rhead)
      relay_after_head(sock, backend, rhead, rbuf, rheaders, headers, target)
    end

    # Everything from the response head onward. Once the head is on the
    # wire the 502 vocabulary is spent: a failure here can only end the
    # connection, never answer it, and rendering a 502 into the middle of
    # a live 200 corrupts the stream the browser is already reading (the
    # second head arrives as body bytes; the page dies of it with no
    # error naming anything). [:close, :body_lost] tells handle to close
    # quietly instead — the stall itself is logged with the request that
    # died, since a relay that goes quiet mid-body is exactly the failure
    # that is otherwise invisible.
    def relay_after_head(sock, backend, rhead, rbuf, rheaders, headers, target)
      begin
        write_all(sock, rhead)

        rlen = content_length(rheaders)
        if chunked?(rheaders)
          # The chunk relay reads the framing to find where the body ends,
          # so it takes the read-ahead itself — handing it bytes already on
          # the wire would send the body twice.
          relay_chunked(backend, sock, rbuf)
        else
          write_all(sock, rbuf) unless rbuf.empty?

          if rlen.nil?
            # No Content-Length and no chunk framing: the body really does
            # end at end of file, because the backend is closing to say so.
            copy_stream(backend, sock)
            return [:close, nil]
          else
            remaining = rlen - rbuf.bytesize
            copy_stream(backend, sock, remaining) if remaining > 0
          end
        end
      rescue EOFError
        @on_error.call("backend for #{headers["host"]}#{target} closed mid-body, " \
                       "before its Content-Length of #{rheaders["content-length"]} was met")
        return [:close, :body_lost]
      rescue IdleTimeout => e
        @on_error.call("response for #{headers["host"]}#{target} died mid-body: #{e.message}")
        return [:close, :body_lost]
      rescue IOError, SystemCallError
        # The client or the backend hung up mid-relay — ordinary web
        # traffic (a cancelled fetch, a departed tab), not a failure.
        return [:close, :body_lost]
      end

      if keep_alive?(headers) && keep_alive?(rheaders)
        # Any bytes beyond Content-Length on the backend are a second
        # pipelined response on a connection we won't reuse — drop.
        [:keep_alive, nil]
      else
        [:close, nil]
      end
    end

    def relay_response_close(backend, sock)
      rhead, rbuf = read_response_head(backend)
      return if rhead.nil?

      write_all(sock, rhead)
      _rm, _rt, rheaders = parse_head(rhead)
      if chunked?(rheaders)
        relay_chunked(backend, sock, rbuf)
      else
        write_all(sock, rbuf) unless rbuf.empty?
        copy_stream(backend, sock)
      end
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
    #
    # A caller may pass its own budget (`timeout:`), which is the only way
    # a timeout escapes as HeadTimeout instead of being flattened into the
    # same [nil, ...] a dead peer returns — see read_response_head for why
    # that distinction is the whole point.
    def read_head(sock, buf, timeout: nil)
      loop do
        if (idx = buf.index("\r\n\r\n"))
          return [buf.byteslice(0, idx + 4), buf.byteslice(idx + 4..) || +""]
        end
        return [nil, buf] if buf.bytesize > MAX_HEAD_BYTES

        buf << read_chunk(sock, CHUNK_BYTES, timeout: timeout)
      end
    rescue IdleTimeout => e
      # A caller that brought its own budget needs to be told a read timed
      # out; everyone else keeps the old contract, where a peer that goes
      # quiet is just another [nil, ...].
      raise HeadTimeout, e.message, e.backtrace if timeout

      [nil, +""]
    rescue EOFError, IOError
      [nil, +""]
    end

    # The response head is read on its own budget, and is the one read
    # where a timeout is allowed out of read_head: until the head arrives
    # the client has no response at all, so "how long do we wait" is a
    # real question with a tunable answer — and the answer is also what
    # makes a retry safe. Once the head is in, the body is on the idle
    # clock, which stays generous for a streaming response.
    def read_response_head(sock)
      read_head(sock, +"", timeout: @head_timeout)
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
    def read_chunk(sock, size, timeout: nil)
      loop do
        result = sock.read_nonblock(size, exception: false)
        return result if result.is_a?(String)
        raise EOFError, "end of file reached" if result.nil?

        wait_for(sock, result, timeout)
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

    # Chunked framing is the one body the proxy has to read rather than
    # copy, because it is the only thing that says where the body ends. It
    # ends at the terminating chunk — not at end of file, and the backend
    # holding the connection open past it is keep-alive doing exactly what
    # it promised. Every streamed page, every ActionController::Live
    # response and every event stream is framed this way.
    #
    # Bytes cross to the client exactly as the backend wrote them; only the
    # framing is read, never rewritten. `buf` is the read-ahead already
    # past the response head.
    def relay_chunked(src, dst, buf)
      loop do
        line = take_line(src, buf)
        return if line.nil?

        write_all(dst, line)
        size = chunk_size(line)
        if size.zero?
          relay_trailers(src, dst, buf)
          return
        end

        write_all(dst, take_bytes(src, buf, size) || +"")
        write_all(dst, take_line(src, buf) || +"")
      end
    end

    # Trailers run to the blank line that closes them.
    def relay_trailers(src, dst, buf)
      loop do
        line = take_line(src, buf)
        return if line.nil?

        write_all(dst, line)
        return if line == CRLF
      end
    end

    # A chunk-size line, less the CRLF that ends it. Extensions after a
    # semicolon are the sender's and are not ours to weigh.
    def chunk_size(line)
      line.split(";", 2).first.to_s.strip.to_i(16)
    end

    def take_line(sock, buf)
      until (index = buf.index(CRLF))
        return nil unless fill_buf(sock, buf)
      end
      buf.slice!(0, index + 2)
    end

    def take_bytes(sock, buf, count)
      out = +""
      while out.bytesize < count
        return nil if buf.empty? && !fill_buf(sock, buf)

        take = [count - out.bytesize, buf.bytesize].min
        out << buf.slice!(0, take)
      end
      out
    end

    def fill_buf(sock, buf)
      buf << read_chunk(sock, CHUNK_BYTES)
      true
    rescue EOFError
      false
    end

    def chunked?(headers)
      headers["transfer-encoding"].to_s.downcase.include?("chunked")
    end

    # Block until the socket is ready for the direction a nonblocking op
    # asked for; a timeout when the bound passes with no progress. A
    # caller-supplied bound only changes how long we wait — what a timeout
    # *means* is read_head's call, because only it knows whether it was
    # waiting on a client, on a body, or on a backend's first word.
    def wait_for(sock, wait_kind, timeout = nil)
      bound = timeout || @idle_timeout
      if wait_kind == :wait_readable
        raise IdleTimeout, "no bytes within #{bound}s" unless readable?(sock, bound)
      elsif !writable?(sock, bound)
        raise IdleTimeout, "no bytes within #{bound}s"
      end
      nil
    end

    # select(2) with the caller's bound (the idle one by default). SSL-
    # buffered bytes count as readable without a syscall. A closed socket
    # raises in select — report not-ready and let the nonblocking op
    # raise the real error.
    def readable?(sock, timeout = @idle_timeout)
      return true if sock.respond_to?(:pending) && sock.pending.positive?

      !IO.select([sock], nil, nil, timeout).nil?
    rescue IOError, SystemCallError
      false
    end

    def writable?(sock, timeout = @idle_timeout)
      !IO.select(nil, [sock], nil, nil, timeout).nil?
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

    # The 502 used to be a fixed 60 bytes: "The target app is not
    # responding." No hostname, no target, no owner, no directory, no log,
    # no next command — so a dead app and a busy one produced byte-identical
    # pages, and a 60-second font request came back with nothing to act on.
    # The two need opposite responses (start it vs. go read why it is
    # stuck), so the page names the app, the backend it points at, which
    # of the two it was, who registered it, where it lives, and the exact
    # command to run. Modeled on render_not_found, which already answers
    # "nobody knows what this hostname is" properly.
    def render_bad_gateway(sock, entry, host, reason = :refused)
      headers = { ERROR_HEADER => error_kind(reason) }
      bare = Hostname.strip_port(host)
      # Same DNS-rebinding boundary as render_not_found: a Host outside our
      # TLDs is a website that got us to answer, not the local developer
      # asking, so it never learns the app's directory or the agent's name.
      return respond(sock, 502, "<h1>Bad Gateway</h1>", headers: headers) unless friendly_host?(bare)

      target = entry ? entry["target"].to_s : ""
      body = "<h1>Bad Gateway</h1><p>#{what_happened(reason, target)}</p>" \
             "#{bad_gateway_owner(entry, bare)}#{bad_gateway_fix(entry, reason)}"
      respond(sock, 502, body, headers: headers)
    rescue IOError, SystemCallError
      nil
    end

    # The machine-readable failure class. Agents branch on this without
    # parsing the page, so each failure must carry its own name — a closed
    # connection labeled "refused", or a proxy out of file descriptors
    # labeled "refused", points the reader at the app when the app is fine.
    def error_kind(reason)
      case reason
      when :silent then "backend-silent"
      when :gone then "backend-gone"
      when :exhausted then "proxy-exhausted"
      when :unreachable then "proxy-unreachable"
      else "backend-refused"
      end
    end

    # Which of the failures this was, said the way each one has to be
    # read: not listening means start the app, silent means go find out
    # why an app that is up is not answering, exhausted means the trouble
    # is the proxy's own resource limit. One "not responding" for all of
    # them sends the reader to the wrong place every time.
    def what_happened(reason, target)
      at = target.empty? ? "" : " at <code>#{escape(target)}</code>"
      case reason
      when :silent
        "The backend#{at} accepted the connection, then sent no response for " \
          "#{format("%.4g", @head_timeout)} seconds — it is up, not down."
      when :gone
        "The backend#{at} accepted the connection, then closed it without " \
          "sending a response."
      when :exhausted
        "The proxy ran out of file descriptors dialing#{at} — the limit is the " \
          "proxy process's own, not the app's, and the backend may be perfectly fine."
      when :unreachable
        "The proxy could not reach the backend#{at} — the address is wrong or the " \
          "path there failed, which is not the same as nothing listening."
      else
        "Nothing is listening#{at}."
      end
    end

    def bad_gateway_owner(entry, host)
      return "" if entry.nil?

      # spec.dir, never Dir.pwd: the proxy runs from somewhere else entirely
      # (a launchd daemon, a worktree of yamine itself), and inside one a
      # Dir.pwd-derived path names the wrong checkout entirely.
      dir = entry.dig("spec", "dir")
      where = dir ? ", app in <code>#{escape(dir)}</code>" : ""
      agent = entry["agent"].to_s
      by = agent.empty? ? "" : " by agent <strong>#{escape(agent)}</strong>"
      return "<p>Registered#{by}#{where}.</p>" if host.empty?

      "<p>The backend for <strong>#{escape(host)}</strong> is registered#{by}#{where}.</p>"
    end

    def bad_gateway_fix(entry, reason)
      if [:exhausted, :unreachable].include?(reason)
        # The app is not the suspect here, so the start command would be
        # the wrong advice on a page that already says so.
        return "<p>The backend looks up — check the proxy's own log: " \
               "<code>proxy.log</code> in the yamine state dir.</p>"
      end

      dir = entry&.dig("spec", "dir")
      return "<p>Start it with <code>yamine start</code> in that app's directory.</p>" unless dir

      log = File.join(dir, "log", "development.log")
      "<p>Start it: <code>cd #{escape(dir)} && yamine start</code></p>" \
        "<p>What it said before it went quiet: <code>#{escape(log)}</code></p>"
    end

    def render_loop(sock, host)
      respond(sock, 508, "<h1>Loop Detected</h1><p>#{escape(host)} passed through " \
                         "yamine too many times. Check dev-server proxy config.</p>")
    rescue IOError, SystemCallError
      nil
    end

    def respond(sock, status, body, headers: {})
      message = { 404 => "Not Found", 502 => "Bad Gateway", 508 => "Loop Detected" }[status]
      extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      write_all(sock, "HTTP/1.1 #{status} #{message}\r\n" \
                      "Content-Type: text/html\r\n" \
                      "#{HEALTH_HEADER}: 1\r\n" \
                      "#{extra}" \
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

# frozen_string_literal: true

require_relative "test_helper"

# A chunked response ends at its terminator, not at end of file. The relay
# only knew one way to end a body with no Content-Length — copy until the
# backend hung up — and it read that as close-delimited. But Rails'
# ActionController::Live, every streamed page and every server-sent-events
# response is chunked, and the backend holding the connection open after the
# terminator is exactly what the framing promised. So the relay blocked in
# copy_stream until the idle bound fired, sixty seconds later, pinned the
# client connection the whole time.
#
# It looked like the app being slow. It looked like the proxy wedging. What
# it did was kill the second request on the connection: the browser sent the
# page's main chunk on the connection the streamed document had just used,
# and nothing came back for a minute. Only requests that opened a fresh
# connection worked, which is why a load test looked perfect and a browser
# did not.
class ProxyChunkedReuseTest < Minitest::Test
  IDLE = 0.3
  HEAD = 0.3

  def with_route(target)
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", target, 0, kind: "tcp")
    yield store
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def proxy_for(store)
    errors = []
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false,
      idle_timeout: IDLE, head_timeout: HEAD,
      on_error: ->(msg) { errors << msg })
    [proxy, errors]
  end

  # One chunked response per connection, then the connection is held open
  # past the terminator — which is what the framing promised and what the
  # relay used to wait on forever. The proxy dials a fresh backend socket
  # per request, so the backend takes a connection per response; what is
  # reused is the client's connection, and that is what this test is about.
  def chunked_backend(requests, hold:)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      requests.times do |i|
        sock = server.accept
        Thread.new(sock, i) do |client, n|
          head = +""
          head << client.gets until head =~ /\r\n\r\n\z/
          body = "chunk#{n}-body"
          client.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
          client.write("#{body.bytesize.to_s(16)}\r\n#{body}\r\n")
          client.write("0\r\n\r\n")
          sleep hold
          client.close rescue nil
        end
      end
    end
    [server, thread]
  end

  # Read until `count` response heads have arrived or the budget runs out.
  # What matters is whether the second request is answered at all.
  def read_until(sock, count, seconds)
    buf = +""
    deadline = Time.now + seconds
    loop do
      return buf if buf.scan("HTTP/1.1 200 OK").size >= count

      remaining = deadline - Time.now
      break if remaining <= 0

      ready = IO.select([sock], nil, nil, remaining)
      break unless ready

      begin
        buf << sock.read_nonblock(65_536)
      rescue IO::WaitReadable
        next
      rescue EOFError, SystemCallError
        # A proxy that gave up mid-test resets the connection. That is the
        # failure under test, so it reads as "nothing more arrived" and
        # lets the assertion name it.
        break
      end
    end
    buf
  end

  def test_chunked_body_ends_at_its_terminator_and_frees_the_connection
    server, backend = chunked_backend(2, hold: IDLE * 2)

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy, _errors = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = Thread.new do
        sock = front.accept
        proxy.send(:handle, sock)
      end

      client = TCPSocket.new("127.0.0.1", front.addr[1])
      client.write(request)
      first = read_until(client, 1, 3)
      client.write(request)
      both = first + read_until(client, 2, 3)

      assert_equal 2, both.scan("HTTP/1.1 200 OK").size,
        "a chunked body ends at its terminator, so the connection is free for the next " \
        "request; every asset fetched after a streamed document depends on it"
      assert_includes both, "chunk1-body", "the second response is the second request's"
      assert both.end_with?("0\r\n\r\n") || both.include?("0\r\n\r\n"),
        "the chunked framing reaches the client intact"
    ensure
      handler&.kill
      client&.close
      front&.close
    end
  ensure
    backend&.kill
    server&.close
  end

  # Chunked bytes are the client's, not ours to re-frame: they cross
  # exactly as the backend wrote them.
  def test_chunked_bytes_cross_untouched
    server, backend = chunked_backend(1, hold: IDLE * 2)

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy, _errors = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = Thread.new do
        sock = front.accept
        proxy.send(:handle, sock)
      end

      client = TCPSocket.new("127.0.0.1", front.addr[1])
      client.write(request)
      response = read_until(client, 1, 3)

      assert response.include?("Transfer-Encoding: chunked")
      assert_includes response, "b\r\nchunk0-body\r\n"
      assert response.rstrip.end_with?("0"), "the terminating chunk is forwarded, not swallowed"
    ensure
      handler&.kill
      client&.close
      front&.close
    end
  ensure
    backend&.kill
    server&.close
  end

  # The case the broken branch was written for still has to work: a body
  # with no length and no chunk framing really does end at end of file.
  def test_close_delimited_body_still_ends_at_end_of_file
    server = TCPServer.new("127.0.0.1", 0)
    body = "close-delimited"
    backend = Thread.new do
      sock = server.accept
      head = +""
      head << sock.gets until head =~ /\r\n\r\n\z/
      sock.write("HTTP/1.1 200 OK\r\n\r\n#{body}")
      sock.close
    end

    with_route("127.0.0.1:#{server.addr[1]}") do |store|
      proxy, _errors = proxy_for(store)
      front = TCPServer.new("127.0.0.1", 0)
      handler = Thread.new do
        sock = front.accept
        proxy.send(:handle, sock)
      end

      client = TCPSocket.new("127.0.0.1", front.addr[1])
      client.write(request)
      response = read_until(client, 1, 3)

      assert_includes response, body
      refute_includes response, "Transfer-Encoding"
    ensure
      handler&.kill
      client&.close
      front&.close
    end
  ensure
    backend&.kill
    server&.close
  end

  private

  def request
    "GET /chat HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: keep-alive\r\n\r\n"
  end
end
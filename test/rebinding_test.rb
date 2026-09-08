# frozen_string_literal: true

require_relative "test_helper"

class RebindingTest < Minitest::Test
  # DNS-rebinding boundary: foreign Hosts get a bare 404 naming nothing;
  # our own TLDs get the helpful route list.
  def proxy_with(routes, tlds: ["localhost"])
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    routes.each { |h| store.add_route(h, "127.0.0.1:4001", 0, kind: "tcp") }
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false, tlds: tlds)
    [proxy, dir]
  end

  def get(port, host)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("GET / HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
    sock.read
  ensure
    sock&.close
  end

  def serve(proxy)
    server = TCPServer.new("127.0.0.1", 0)
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
    [server.addr[1], server, accept]
  end

  def test_foreign_host_gets_bare_404
    proxy, dir = proxy_with(["myapp.localhost"])
    port, server, accept = serve(proxy)
    response = get(port, "evil.example.com")
    assert_includes response, "404"
    refute_includes response, "myapp.localhost",
      "route names must never leak to foreign hosts"
    refute_includes response, "No app registered"
  ensure
    accept&.kill
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_own_tld_gets_helpful_404
    proxy, dir = proxy_with(["myapp.localhost"])
    port, server, accept = serve(proxy)
    response = get(port, "unknown.localhost")
    assert_includes response, "404"
    assert_includes response, "myapp.localhost"
  ensure
    accept&.kill
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_custom_tld_boundary
    proxy, dir = proxy_with(["myapp.preview.example.com"],
      tlds: ["preview.example.com"])
    port, server, accept = serve(proxy)
    friendly = get(port, "other.preview.example.com")
    assert_includes friendly, "myapp.preview.example.com"
    foreign = get(port, "other.localhost")
    refute_includes foreign, "myapp.preview.example.com"
  ensure
    accept&.kill
    server&.close
    FileUtils.remove_entry(dir) if dir
  end
end

class MtimeCacheTest < Minitest::Test
  # A route registered a millisecond ago must be routable immediately:
  # mtime-keyed cache has no TTL race for boot-then-curl agents.
  def test_fresh_route_visible_immediately
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false)
    backend = TCPServer.new("127.0.0.1", 0)
    bport = backend.addr[1]
    serve_backend = Thread.new do
      s = backend.accept
      head = +""
      while (l = s.gets)
        head << l
        break if head =~ /\r\n\r\n\z/
      end
      body = "fresh"
      s.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      s.close
    end

    store.add_route("fresh.localhost", "127.0.0.1:#{bport}", 0, kind: "tcp")
    server = TCPServer.new("127.0.0.1", 0)
    pport = server.addr[1]
    accept = Thread.new do
      s = server.accept
      proxy.send(:handle, s)
    end
    sock = TCPSocket.new("127.0.0.1", pport)
    sock.write("GET / HTTP/1.1\r\nHost: fresh.localhost\r\nConnection: close\r\n\r\n")
    assert_includes sock.read, "fresh"
  ensure
    serve_backend&.join(2)
    sock&.close
    accept&.kill
    server&.close
    backend&.close
    FileUtils.remove_entry(dir) if dir
  end
end

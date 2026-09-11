# frozen_string_literal: true

require_relative "test_helper"

class ProxyRoutingTest < Minitest::Test
  def proxy
    @proxy ||= Yamine::Proxy.new(store: nil)
  end

  def routes
    [
      { "hostname" => "myapp.localhost", "target" => "127.0.0.1:4001", "kind" => "tcp", "pid" => 1 },
      { "hostname" => "api.myapp.localhost", "target" => "127.0.0.1:4002", "kind" => "tcp", "pid" => 2 }
    ]
  end

  def test_exact_match_wins
    assert_equal "myapp.localhost", proxy.route("myapp.localhost", routes)["hostname"]
  end

  def test_port_stripped_before_routing
    assert_equal "myapp.localhost", proxy.route("myapp.localhost:443", routes)["hostname"]
  end

  def test_subdomain_falls_back_to_parent_only_when_opted_in
    assert_nil proxy.route("tenant1.myapp.localhost", routes),
      "an unopted route must not capture subdomains"

    opted_in = routes.map { |r| r.merge("subdomains" => true) }
    assert_equal "myapp.localhost",
      proxy.route("tenant1.myapp.localhost", opted_in)["hostname"]
  end

  # The hazard this exists to kill: a worktree's URL, with its stack
  # stopped, used to resolve to the main checkout through the wildcard —
  # a working app running the wrong code, indistinguishable from the
  # right one. It must miss instead.
  def test_stopped_worktree_url_does_not_resolve_to_the_parent
    assert_nil proxy.route("work-next.myapp.localhost", routes)
  end

  def test_exact_beats_wildcard
    assert_equal "api.myapp.localhost",
      proxy.route("api.myapp.localhost", routes)["hostname"]

    opted_in = routes.map { |r| r.merge("subdomains" => true) }
    assert_equal "api.myapp.localhost",
      proxy.route("api.myapp.localhost", opted_in)["hostname"]
  end

  def test_unknown_returns_nil
    assert_nil proxy.route("nope.localhost", routes)
  end

  def test_hop_limit
    assert_nil proxy.check_hops({})
    assert_nil proxy.check_hops({ "x-yamine-hops" => "4" })
    assert_equal 5, proxy.check_hops({ "x-yamine-hops" => "5" })
  end
end

class ProxyLiveTest < Minitest::Test
  # End-to-end through a real TCP backend on an ephemeral port.
  def test_proxies_to_tcp_backend
    backend = TCPServer.new("127.0.0.1", 0)
    backend_port = backend.addr[1]
    Thread.new do
      sock = backend.accept
      head = +""
      head << sock.gets while head !~ /\r\n\r\n\z/
      body = "hello-backend"
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      sock.close
    end

    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:#{backend_port}", 0, kind: "tcp")

    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    proxy_port = server.addr[1]
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end

    sock = TCPSocket.new("127.0.0.1", proxy_port)
    sock.write("GET / HTTP/1.1\r\nHost: myapp.localhost\r\nConnection: close\r\n\r\n")
    response = sock.read
    assert_includes response, "hello-backend"
  ensure
    backend&.close
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_unknown_host_404_lists_routes
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:9", 0, kind: "tcp")

    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    proxy_port = server.addr[1]
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end

    sock = TCPSocket.new("127.0.0.1", proxy_port)
    sock.write("GET / HTTP/1.1\r\nHost: nope.localhost\r\nConnection: close\r\n\r\n")
    response = sock.read
    assert_includes response, "404"
    assert_includes response, "myapp.localhost"
  ensure
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  # A worktree-shaped miss: the parent app is live, the label is not.
  # The page names the parent and its directory so the wrong-looking
  # answer becomes an instruction.
  def test_worktree_shaped_miss_names_the_parent_and_its_directory
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("myapp.localhost", "127.0.0.1:9", 0, kind: "tcp",
      spec: { "dir" => "/code/myapp" })

    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false)
    server = TCPServer.new("127.0.0.1", 0)
    proxy_port = server.addr[1]
    Thread.new do
      sock = server.accept
      proxy.send(:handle, sock)
    end

    sock = TCPSocket.new("127.0.0.1", proxy_port)
    sock.write("GET / HTTP/1.1\r\nHost: my-branch.myapp.localhost\r\nConnection: close\r\n\r\n")
    response = sock.read
    assert_includes response, "404"
    assert_includes response, "my-branch.myapp.localhost"
    assert_includes response, "myapp.localhost"
    assert_includes response, "/code/myapp"
    assert_includes response, "yamine start"
  ensure
    server&.close
    FileUtils.remove_entry(dir) if dir
  end
end

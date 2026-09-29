# frozen_string_literal: true

require_relative "test_helper"

class SupervisorTest < Minitest::Test
  def setup
    @state = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@state)
    @app_dir = Dir.mktmpdir
    @runner = Yamine::Runner.new(store: @store, on_log: ->(m) {})
    @listeners = []
    @extra_pids = []
    @events = []
  end

  def teardown
    @listeners.each { |l| l.close rescue nil }
    @extra_pids.each { |p| Process.kill("KILL", p) rescue nil }
    FileUtils.remove_entry(@state)
    FileUtils.remove_entry(@app_dir)
  end

  def supervisor(idle_timeout: 900, interval: 5, runner: @runner)
    Yamine::Supervisor.new(store: @store, runner: runner,
      interval: interval, idle_timeout: idle_timeout,
      on_event: ->(m) { @events << m })
  end

  # A "backend" is a listening unix socket; the sidecar pid is a real
  # sleeping process so kill paths are exercised for real.
  def supervised_route
    socket_path = File.join(@app_dir, "app.sock")
    @store.add_route("app.localhost", socket_path, Process.pid,
      kind: "socket", spec: { "dir" => @app_dir })
    spawn_backend(socket_path)
    @store.find("app.localhost")
  end

  # A listening target and a sidecar naming a live process, which is
  # what a boot leaves behind. Shared so a second backend on the same
  # route (the boot-on-request case) is built the same way as the first.
  # A nil target is a route whose target is an address, not a file.
  def spawn_backend(target, hostname: "app.localhost")
    @listeners << UNIXServer.new(target) if target
    pid = spawn("sleep", "30", out: File::NULL, err: File::NULL)
    Process.detach(pid)
    @extra_pids << pid
    File.write(File.join(@state, "backend-#{hostname}.pid"), "#{pid}\n")
    pid
  end

  # A route as `yamine start` registers it: kind "tcp", a spec carrying
  # the app's directory, a sidecar naming the `sh -c` shell the boot
  # wrapped the app in. Nothing else about a start-route is different,
  # which is the whole reason it used to be invisible to the daemon.
  def tcp_route
    @tcp_port = Yamine::Ports.find_free
    @tcp_server = TCPServer.new("127.0.0.1", @tcp_port)
    @store.add_route("tcp.localhost", "127.0.0.1:#{@tcp_port}", Process.pid,
      kind: "tcp", spec: { "dir" => @app_dir, "proc" => "web" })
    spawn_backend(nil, hostname: "tcp.localhost")
  end

  def touch_restart_file
    FileUtils.mkdir_p(File.join(@app_dir, "tmp"))
    FileUtils.touch(File.join(@app_dir, "tmp", "restart.txt"))
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end

  def sidecar_pid(hostname = "app.localhost")
    File.read(File.join(@state, "backend-#{hostname}.pid")).to_i
  end

  # A spec with a directory is the whole test: that is all the daemon
  # needs to watch a route. Both kinds qualify, and `yamine start`
  # registers tcp — excluding it is what made `yamine restart` a no-op
  # for every app yamine started. A spec is still required: a static
  # alias or a hand-written route has no app to watch.
  def test_supervised_needs_a_spec_with_a_dir_in_either_kind
    sup = supervisor
    assert sup.supervised?({ "kind" => "socket", "spec" => { "dir" => "/x" } })
    assert sup.supervised?({ "kind" => "tcp", "spec" => { "dir" => "/x" } })
    refute sup.supervised?({ "kind" => "socket" })
    refute sup.supervised?({ "kind" => "tcp" })
    refute sup.supervised?({ "kind" => "socket", "spec" => {} })
    refute sup.supervised?({ "kind" => "socket", "target" => "/x.sock" })
  end

  # The fix itself: `yamine restart` in a directory a `yamine start`
  # booted from now reaches the daemon and stops the backend.
  def test_tcp_route_with_spec_restarts_on_restart_txt
    pid = tcp_route
    sup = supervisor
    sup.tick # first sighting: baseline, no action
    assert alive?(pid)

    sleep 0.05
    touch_restart_file
    sup.tick

    refute alive?(pid), "a yamine start route must honour tmp/restart.txt"
    refute File.file?(File.join(@state, "backend-tcp.localhost.pid"))
  end

  # The first `yamine restart` an app is ever given. The file did not
  # exist when the daemon first saw the route, so the baseline it took
  # was "no file" — and re-deriving that baseline on every pass absorbed
  # the change: the new mtime became the baseline and the restart that
  # was asked for was the one that got missed. This is pinned on a
  # socket route, which is the kind that had it before tcp routes were
  # watched at all.
  def test_first_restart_ever_is_not_swallowed_by_the_baseline
    supervised_route
    pid = sidecar_pid
    sup = supervisor
    sup.tick # baseline: no restart.txt yet

    touch_restart_file
    sup.tick

    refute alive?(pid), "the first restart.txt an app ever gets must be acted on"
  end

  # Liveness is asked of the app, and a tcp route's app is a port. The
  # daemon used to be able to answer this for socket routes only, which
  # is why "is it up" was a question only one kind of route could be
  # asked about.
  def test_backend_alive_covers_both_kinds
    socket_path = File.join(@app_dir, "probe.sock")
    port = Yamine::Ports.find_free
    @listeners << TCPServer.new("127.0.0.1", port)
    sup = supervisor

    refute sup.backend_alive?({ "kind" => "socket", "target" => socket_path })
    @listeners << UNIXServer.new(socket_path)
    assert sup.backend_alive?({ "kind" => "socket", "target" => socket_path })

    assert sup.backend_alive?({ "kind" => "tcp", "target" => "127.0.0.1:#{port}" })
    closed = Yamine::Ports.find_free
    refute sup.backend_alive?({ "kind" => "tcp", "target" => "127.0.0.1:#{closed}" })
    refute sup.backend_alive?({ "kind" => "alias", "target" => "127.0.0.1:#{port}" })
  end

  # The event a dead backend produces used to promise a reboot. For a
  # tcp route that promise is not one yamine can keep — there is no
  # command in the route to re-run — so it says what to do instead.
  def test_down_event_for_a_tcp_route_does_not_promise_a_reboot
    tcp_route
    sup = supervisor
    sup.tick # baseline
    FileUtils.rm_f(File.join(@state, "backend-tcp.localhost.pid"))
    @tcp_server.close # nothing is listening on the port any more

    sup.tick

    assert @events.any? { |m| m.include?("down") && m.include?(@app_dir) },
      "expected a down event naming the directory to start it in, got: #{@events.inspect}"
    refute @events.any? { |m| m.include?("will boot on next request") },
      "a tcp route cannot be booted on request; promising it is the old lie"
  end

  # Watching a tcp route and idle-killing it are different decisions, and
  # only one of them is safe by default. The daemon cannot boot a tcp
  # backend on request (rebootable?), so an idle kill it performed would
  # be a one-way trip: the app is gone and nothing brings it back until a
  # human runs `yamine start`. That is not a default to impose on every
  # `yamine start` app the moment it becomes supervised — so tcp routes
  # are watched (restart.txt, crash detection) but not idle-killed.
  def test_tcp_route_is_not_idle_killed_by_default
    pid = tcp_route
    sup = supervisor(idle_timeout: 0.1)
    sup.tick
    sleep 0.3
    sup.tick

    assert alive?(pid), "a tcp route must not be idle-killed while the daemon cannot reboot it"
  end

  # And for a machine that wants puma-dev's semantics for `yamine start`
  # apps too, the opt-in is one env var away.
  def test_tcp_route_idle_kills_when_opted_in
    pid = tcp_route
    ENV["YAMINE_IDLE_TCP"] = "1"
    sup = supervisor(idle_timeout: 0.1)
    sup.tick
    sleep 0.3
    sup.tick

    refute alive?(pid), "YAMINE_IDLE_TCP opts a tcp route into the idle clock"
  ensure
    ENV.delete("YAMINE_IDLE_TCP")
  end

  # The restart latch exists to stop a second kill landing on a backend
  # that is already down — not to supervise each route exactly once. It
  # was never cleared, so a route that had restarted once (or been seen
  # down once) was invisible to the daemon for the rest of its life, and
  # the second `yamine restart` was the no-op this change removes.
  def test_restart_watch_comes_back_when_the_app_does
    route = supervised_route
    first = sidecar_pid
    sup = supervisor
    sup.tick # baseline
    sleep 0.05
    touch_restart_file
    sup.tick
    refute alive?(first), "the first restart.txt change must be acted on"

    # The app is back — in the real system, booted on the next request.
    second = spawn_backend(route["target"])
    sup.tick
    sleep 0.05
    touch_restart_file
    sup.tick

    refute alive?(second), "a later restart.txt change must be acted on too"
  end

  def test_restart_txt_change_kills_backend
    route = supervised_route
    pid = sidecar_pid
    FileUtils.mkdir_p(File.join(@app_dir, "tmp"))
    FileUtils.touch(File.join(@app_dir, "tmp", "restart.txt"))
    sup = supervisor
    sup.tick # first sighting: baseline, no action
    assert alive?(pid)

    sleep 0.05
    FileUtils.touch(File.join(@app_dir, "tmp", "restart.txt"))
    sup.tick

    refute alive?(pid), "backend should be killed on restart.txt change"
    refute File.file?(File.join(@state, "backend-app.localhost.pid"))
    refute File.socket?(route["target"])
  end

  def test_dead_backend_marked_then_boots_on_request
    route = supervised_route
    pid = sidecar_pid
    Process.kill("KILL", pid)
    Process.wait(pid) rescue nil
    FileUtils.rm_f(route["target"])

    boot_count = 0
    fake_runner = Object.new
    fake_runner.define_singleton_method(:boot_supervised) do |name:, hostname:, url:, dir:|
      boot_count += 1
      @reboot_listener = UNIXServer.new(route["target"])
      Yamine::Runner::App.new(name: name, hostname: hostname, url: url,
        pid: 0, target: route["target"], kind: "socket", command: nil)
    end
    Minitest.after_run { (@reboot_listener&.close rescue nil) }
    sup = supervisor(runner: fake_runner)

    sup.tick # marks dead
    result = sup.ensure_running(@store.find("app.localhost"))
    refute_nil result
    assert_equal 1, boot_count
    assert_equal @app_dir, route.dig("spec", "dir")

    # Socket is alive now (fake boot created it): no second boot.
    sup.ensure_running(@store.find("app.localhost"))
    assert_equal 1, boot_count

    @listeners << @reboot_listener if @reboot_listener
  end

  def test_idle_backend_killed
    supervised_route
    pid = sidecar_pid
    sup = supervisor(idle_timeout: 0.1)

    sup.tick # baseline
    sleep 0.3
    sup.tick

    refute alive?(pid), "idle backend should be killed"
  end

  def test_fresh_backend_not_idle_killed
    supervised_route
    # The gap has to stay well inside the idle window, not just inside
    # it: `sleep` overshoots by however long the runner is busy, and at
    # 0.05s against a 0.1s window any 50ms of scheduler noise crossed
    # the threshold and killed a backend that was never idle. A 10x
    # ratio keeps the assertion identical -- a second tick inside the
    # window must not kill -- with slack a loaded runner cannot eat.
    sup = supervisor(idle_timeout: 1.0)
    sup.tick
    sleep 0.1
    sup.tick
    assert File.file?(File.join(@state, "backend-app.localhost.pid")),
      "freshly seen backend must not be killed before its idle window"
  end

  # Supervision follows the spec, not the kind: a tcp route with no
  # directory in it is not an app yamine booted, so nothing watches it
  # and an idle clock passes it by. (With a spec, the same route IS
  # watched — see test_tcp_route_with_spec_restarts_on_restart_txt.)
  def test_tcp_route_without_a_spec_is_not_supervised
    @store.add_route("tcp.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    sup = supervisor(idle_timeout: 0.05)
    sleep 0.15
    sup.tick
    assert @store.find("tcp.localhost"), "tcp route must survive"
    assert_empty @events
  end

  def test_shutdown_kills_all_supervised
    supervised_route
    pid = sidecar_pid
    sup = supervisor
    sup.tick
    sup.shutdown
    refute alive?(pid)
  end

  # Daemon shutdown is the puma-dev contract: the apps the daemon booted
  # go down with it. It is not a licence to take down every `yamine
  # start` app on the machine when the proxy is restarted — those have a
  # supervising process of their own, and the proxy is only the listener
  # in front of them.
  def test_shutdown_leaves_a_tcp_route_alone
    pid = tcp_route
    sup = supervisor
    sup.tick
    sup.shutdown

    assert alive?(pid), "the proxy going down must not stop a yamine start app"
    assert File.file?(File.join(@state, "backend-tcp.localhost.pid"))
  end
end


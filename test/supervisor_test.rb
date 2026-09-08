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
    @listeners << UNIXServer.new(socket_path)
    pid = spawn("sleep", "30", out: File::NULL, err: File::NULL)
    Process.detach(pid)
    @extra_pids << pid
    @store.add_route("app.localhost", socket_path, Process.pid,
      kind: "socket", spec: { "dir" => @app_dir })
    File.write(File.join(@state, "backend-app.localhost.pid"), "#{pid}\n")
    @store.find("app.localhost")
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end

  def sidecar_pid
    File.read(File.join(@state, "backend-app.localhost.pid")).to_i
  end

  def test_supervised_only_socket_routes_with_spec
    sup = supervisor
    refute sup.supervised?({ "kind" => "tcp", "spec" => { "dir" => "/x" } })
    refute sup.supervised?({ "kind" => "socket" })
    assert sup.supervised?({ "kind" => "socket", "spec" => { "dir" => "/x" } })
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
    sup = supervisor(idle_timeout: 0.1)
    sup.tick
    sleep 0.05
    sup.tick
    assert File.file?(File.join(@state, "backend-app.localhost.pid")),
      "freshly seen backend must not be killed before its idle window"
  end

  def test_tcp_routes_never_supervised
    @store.add_route("tcp.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    sup = supervisor(idle_timeout: 0.05)
    sleep 0.15
    sup.tick
    assert @store.find("tcp.localhost"), "tcp route must survive"
  end

  def test_shutdown_kills_all_supervised
    supervised_route
    pid = sidecar_pid
    sup = supervisor
    sup.tick
    sup.shutdown
    refute alive?(pid)
  end
end


# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "rbconfig"

# Boot-path tests for --wait: concurrent health waits, DB warning,
# opt-out, and per-process healthcheck. Faked backends via Tempfile
# so there is no bundler/rvm shim edge case.

class BootWaitTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @state
    Dir.chdir(@dir)
    FileUtils.mkdir_p(File.join(@dir, "config"))
    @pids = []
    @tmps = []
  end

  def teardown
    Dir.chdir(@orig_dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
    (@pids || []).each { |pid| Process.kill("TERM", pid) rescue nil }
    (@tmps || []).each { |t| t.unlink rescue nil }
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
    ENV.delete("DATABASE_URL")
  end

  def write_config(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def spawn_tcp(port)
    tmp = Tempfile.new(["fake-", ".rb"])
    tmp.write("require \"socket\"; s = TCPServer.new(\"127.0.0.1\", #{port}); loop{c=s.accept; c.write(\"ok\") rescue nil; c.close rescue nil}\n")
    tmp.close
    pid = spawn(RbConfig.ruby, tmp.path)
    Process.detach(pid)
    sleep 0.6
    @pids << pid
    @tmps << tmp
    pid
  end

  def spawn_crash(port)
    tmp = Tempfile.new(["fake-crash-", ".rb"])
    tmp.write("require \"socket\"; s = TCPServer.new(\"127.0.0.1\", #{port}); c=s.accept; c.close rescue nil; exit 1\n")
    tmp.close
    pid = spawn(RbConfig.ruby, tmp.path)
    Process.detach(pid)
    sleep 0.6
    @pids << pid
    @tmps << tmp
    pid
  end

  # --wait is default (no --no-wait), --wait as explicit alias, --no-wait opts out.
  def test_default_is_wait
    ctx = Yamine::CLI::Context.new
    opts = ctx.parse_flags([], %i[variant tld force app_port wait no_wait json])
    assert_nil opts[:wait]
    assert_nil opts[:no_wait]
    # boot_all treats absence of --no-wait as wait
    assert !opts[:no_wait]
  end

  def test_wait_alias_parsed
    ctx = Yamine::CLI::Context.new
    opts = ctx.parse_flags(["--wait"], %i[variant tld force app_port wait no_wait json])
    assert opts[:wait]
    assert_nil opts[:no_wait]
  end

  def test_no_wait_opts_out
    ctx = Yamine::CLI::Context.new
    opts = ctx.parse_flags(["--no-wait"], %i[variant tld force app_port wait no_wait json])
    assert opts[:no_wait]
    assert_nil opts[:wait]
  end

  def test_wait_json_both_parsed
    ctx = Yamine::CLI::Context.new
    opts = ctx.parse_flags(["--wait", "--json"], %i[variant tld force app_port wait no_wait json])
    assert opts[:wait]
    assert opts[:json]
  end

  # Healthcheck in config validates.
  def test_healthcheck_path_validates
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n    healthcheck:\n      path: /up\n      timeout: 10\n")
    config = Yamine::Config.load(@dir)
    assert_equal "/up", config.processes["web"]["healthcheck"]["path"]
    assert_equal 10, config.processes["web"]["healthcheck"]["timeout"]
  end

  def test_healthcheck_bare_path_validates
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n    healthcheck:\n      path: /health\n")
    config = Yamine::Config.load(@dir)
    assert_equal "/health", config.processes["web"]["healthcheck"]["path"]
  end

  def test_healthcheck_bad_timeout_rejected
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n    healthcheck:\n      timeout: \"fast\"\n")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  # db: false opt-out.
  def test_db_false_resolves
    write_config("service: myapp\ndb: false\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n")
    resolved = Yamine::Resolver.resolve(@dir)
    assert_equal false, resolved.db
  end

  def test_db_false_suppresses_setup
    write_config("service: myapp\ndb: false\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n")
    File.write(File.join(@dir, "config", "database.yml"), "development:\n  adapter: postgresql\n")
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    _out, err = capture_io { Yamine::CLI::BootCommand.send(:setup_database, Yamine::CLI::Context.new, resolved, "myapp_development") }
    assert_empty err.strip
  end

  # Template discovery: env.clear DATABASE_URL found via top-level env.
  def test_template_found_in_top_level_env_clear
    write_config("service: myapp\nenv:\n  clear:\n    DATABASE_URL: postgres://u@/myapp_development\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n")
    resolved = Yamine::Resolver.resolve(@dir)
    assert_equal "postgres://u@/myapp_development", Yamine::CLI::BootCommand.send(:database_template_from_config, resolved)
  end

  # WaitPayload shapes.
  def test_wait_payload_success_includes_db_when_present
    resolved = Struct.new(:app).new("myapp")
    payload = Yamine::WaitPayload.success(resolved, [{ name: "web", status: "ok", duration_ms: 10 }],
      urls: { "web" => "https://myapp.localhost" }, db_name: "myapp_development",
      db_url: "postgres://u@/myapp_development", created: true)
    assert payload[:ok]
    assert_equal "myapp_development", payload[:db][:name]
  end

  def test_wait_payload_success_omits_db_when_absent
    resolved = Struct.new(:app).new("myapp")
    payload = Yamine::WaitPayload.success(resolved, [{ name: "web", status: "ok", duration_ms: 10 }],
      urls: { "web" => "https://myapp.localhost" }, db_name: nil, db_url: nil, created: false)
    assert_nil payload[:db]
  end

  # boot_run registers via adopt with spec; direct check that ownership would work.
  def test_boot_run_registers_spec
    store = Yamine::RouteStore.new(@state)
    runner = Yamine::Runner.new(store: store, on_log: ->(m) {})
    port = Yamine::Ports.find_free
    app = runner.boot_run(name: "web", hostname: "myapp.localhost",
      url: "https://myapp.localhost", dir: @dir,
      command: ["sh", "-c", "sleep 999"], port: port)
    entry = store.find("myapp.localhost")
    assert_equal @dir, entry["spec"]["dir"]
    assert_equal "web", entry["spec"]["proc"]
  ensure
    Process.kill("TERM", app.pid) rescue nil if app
  end
end

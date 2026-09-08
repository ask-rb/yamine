# frozen_string_literal: true

require_relative "test_helper"

class SetupCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["ASK_LOCAL_STATE_DIR"]
    ENV["ASK_LOCAL_STATE_DIR"] = @dir
    @ctx = Ask::Local::CLI::Context.new
  end

  def teardown
    ENV["ASK_LOCAL_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir)
  end

  def capture
    out, err = StringIO.new, StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      yield
      0
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def test_help_describes_default_and_no_service_paths
    _code, out, = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, ["--help"]) }
    assert_includes out, "Default: install the root proxy service on 443"
    assert_includes out, "--no-service"
    assert_includes out, "syncing /etc/hosts"
    assert_includes out, "doctor"
  end

  def test_full_run_with_stubbed_steps
    Ask::Local::CLI::SystemCommand.stubs(:ensure_root_service).returns(true)
    Ask::Local::Hosts.stubs(:sync).returns(true)
    Ask::Local::Doctor.stubs(:run).returns([])
    Ask::Local::Doctor.stubs(:print).returns(0)

    code, out, = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, []) }
    assert_equal 0, code
    assert_includes out, "1/3 Installing proxy service on port 443 (trusts CA)"
    assert_includes out, "2/3 Syncing /etc/hosts"
    assert_includes out, "3/3 Verifying with doctor"
    assert_includes out, "Setup complete"
  end

  def test_no_service_flag_uses_sudo_daemon
    Ask::Local::Trust.stubs(:trust).returns({ trusted: true })
    Ask::Local::CLI::SystemCommand.stubs(:ensure_sudo_daemon).returns(true)
    Ask::Local::Hosts.stubs(:sync).returns(true)
    Ask::Local::Doctor.stubs(:run).returns([])
    Ask::Local::Doctor.stubs(:print).returns(0)

    code, out, = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, ["--no-service"]) }
    assert_equal 0, code
    assert_includes out, "1/4 Trusting local CA"
    assert_includes out, "2/4 Starting proxy sudo daemon on port 443"
    assert_includes out, "3/4 Syncing /etc/hosts"
    assert_includes out, "4/4 Verifying with doctor"
    assert_includes out, "Setup complete"
  end

  def test_root_service_failure_aborts_with_fallback
    Ask::Local::CLI::SystemCommand.stubs(:ensure_root_service).returns(false)

    code, _out, err = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, []) }
    assert_equal 1, code
    assert_includes err, "Setup failed"
    assert_includes err, "Could not install the proxy service"
    assert_includes err, "--no-service"
  end

  def test_trust_failure_aborts_with_manual_fix
    Ask::Local::Trust.stubs(:trust).returns({ trusted: false, error: "nope" })

    code, _out, err = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, ["--no-service"]) }
    assert_equal 1, code
    assert_includes err, "Setup failed: CA trust failed: nope"
    assert_includes err, "ask-local trust"
    assert_includes err, "ask-local setup"
  end

  def test_doctor_failure_aborts_with_count
    Ask::Local::CLI::SystemCommand.stubs(:ensure_root_service).returns(true)
    Ask::Local::Hosts.stubs(:sync).returns(true)
    Ask::Local::Doctor.stubs(:run).returns([])
    Ask::Local::Doctor.stubs(:print).returns(2)

    code, _out, err = capture { Ask::Local::CLI::SystemCommand.setup(@ctx, []) }
    assert_equal 1, code
    assert_includes err, "2 failing check(s)"
  end
end

class EnsureProxyHardErrorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["ASK_LOCAL_STATE_DIR"]
    ENV["ASK_LOCAL_STATE_DIR"] = @dir
    @ctx = Ask::Local::CLI::Context.new
  end

  def teardown
    ENV["ASK_LOCAL_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir)
  end

  def capture_err
    _out, err = StringIO.new, StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = _out, err
    code = begin
      yield
      0
    rescue SystemExit => e
      e.status
    end
    [code, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def with_env(vars)
    orig = {}
    vars.each { |k, v| orig[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    orig.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Non-interactive + privileged port + nothing listening: hard error
  # pointing at setup. No silent :1355 fallback, ever.
  def test_noninteractive_privileged_is_hard_error
    with_env("CI" => "1", "ASK_LOCAL_PORT" => nil) do
      $stdin.stubs(:tty?).returns(false)
      code, err = capture_err do
        Ask::Local::CLI::BootCommand.ensure_proxy!(@ctx)
      end
      assert_equal 1, code
      assert_includes err, "ask-local setup"
      refute_includes err, "1355"
    end
  end

  # Foreign process on the proxy port: hard error, no fallback.
  def test_foreign_process_on_port_is_hard_error
    squatter = TCPServer.new("127.0.0.1", 0)
    port = squatter.addr[1]
    with_env("ASK_LOCAL_PORT" => port.to_s) do
      code, err = capture_err do
        Ask::Local::CLI::BootCommand.ensure_proxy!(@ctx)
      end
      assert_equal 1, code
      assert_includes err, "in use by another process"
    end
  ensure
    squatter&.close
  end

  # A responding foreign server is classified fast (no 5s TLS retry):
  # any HTTP response without our header is definitively foreign.
  def test_responding_foreign_server_classified_fast
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accept = Thread.new do
      loop do
        begin
          s = server.accept
          head = +""
          while (l = s.gets)
            head << l
            break if head =~ /\r\n\r\n\z/
          end
          s.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")
          s.close
        rescue StandardError
          break
        end
      end
    end
    t = Time.now
    refute Ask::Local::ProxyControl.ours?(port, tls: true)
    assert Time.now - t < 4, "responding foreign server must classify fast"
  ensure
    accept&.kill
    server&.close
  end

  # Daemon spawn failure surfaces the fix, not a fallback port.
  def test_spawn_failure_points_at_setup
    with_env("ASK_LOCAL_PORT" => nil) do
      Ask::Local::ProxyControl.stubs(:listening?).returns(false)
      Ask::Local::ProxyControl.stubs(:root?).returns(false)
      @ctx.stubs(:interactive?).returns(true)
      Ask::Local::ProxyControl.stubs(:spawn_daemon)
        .raises(Ask::Local::ProxyNotRunningError.new("Proxy did not start on port 443."))
      code, err = capture_err do
        Ask::Local::CLI::BootCommand.ensure_proxy!(@ctx)
      end
      assert_equal 1, code
      assert_includes err, "ask-local setup"
      refute_includes err, "1355"
    end
  end

  # Explicit opt-in honesty: a custom port flows into the URL verbatim.
  def test_explicit_port_is_honest_in_url
    url = Ask::Local::Hostname.url("myapp.localhost", port: 1355, tls: true)
    assert_equal "https://myapp.localhost:1355", url
    clean = Ask::Local::Hostname.url("myapp.localhost", port: 443, tls: true)
    assert_equal "https://myapp.localhost", clean
  end
end

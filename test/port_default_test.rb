# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "socket"

# The recorded proxy port is machine-wide sticky state. Trusting it even
# when nothing is listening meant a one-off `proxy start -p 1355` (CI, a
# sandbox, a gem-dev foreground proxy) outlived its process and made the
# NEXT boot raise a fresh proxy on 1355 — putting a port in every URL
# again, which is the single outcome yamine exists to prevent.
class PortStickinessTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_port = ENV["YAMINE_PORT"]
    ENV.delete("YAMINE_PORT")
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    if @orig_port
      ENV["YAMINE_PORT"] = @orig_port
    else
      ENV.delete("YAMINE_PORT")
    end
    FileUtils.remove_entry(@dir) rescue nil
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def ctx
    Yamine::CLI::Context.new
  end

  def test_stale_port_file_falls_back_to_default
    dead = free_port
    File.write(File.join(@dir, "proxy.port"), "#{dead}\n")

    assert_equal 443, ctx.proxy_port,
      "a recorded port nobody is listening on must not be reused"
  end

  def test_live_recorded_port_is_honored
    port = free_port
    server = TCPServer.new("127.0.0.1", port)
    File.write(File.join(@dir, "proxy.port"), "#{port}\n")

    assert_equal port, ctx.proxy_port
  ensure
    server&.close
  end

  def test_explicit_env_wins_over_stale_file
    dead = free_port
    File.write(File.join(@dir, "proxy.port"), "#{dead}\n")
    ENV["YAMINE_PORT"] = "9123"

    assert_equal 9123, ctx.proxy_port
  end

  def test_no_port_file_means_default
    assert_equal 443, ctx.proxy_port
  end
end

# warn_non_default_port is the boot-time notice: attaching to a proxy on
# a non-default port is allowed (CI opts in deliberately) but must be
# said out loud, because the resulting :PORT leaks into OAuth callbacks
# and webhooks.
class NonDefaultPortWarningTest < Minitest::Test
  def with_env_port(value)
    orig = ENV["YAMINE_PORT"]
    value ? ENV["YAMINE_PORT"] = value : ENV.delete("YAMINE_PORT")
    yield
  ensure
    if orig
      ENV["YAMINE_PORT"] = orig
    else
      ENV.delete("YAMINE_PORT")
    end
  end

  def warning_for(port, env_port: nil)
    with_env_port(env_port) do
      _out, err = capture_io do
        Yamine::CLI::BootCommand.send(:warn_non_default_port, port, true)
      end
      err
    end
  end

  def test_warns_on_non_default_port
    output = warning_for(1355)

    assert_match(/:1355/, output)
    assert_match(/yamine setup/, output)
  end

  def test_silent_when_the_port_was_explicitly_requested
    assert_empty warning_for(1355, env_port: "1355")
  end

  def test_silent_on_default_port
    assert_empty warning_for(443)
  end
end

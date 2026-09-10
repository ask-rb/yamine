# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# A proxy on a non-default port is legitimate (CI, sandboxes opt in with
# `-p`) but it makes every URL carry :PORT — the one thing yamine exists
# to avoid. doctor used to report a stale dev proxy on 1355 as a bare
# "[ok] listening on port 1355", which is how one leftover foreground
# proxy silently downgraded every project on the machine.
class DoctorPortWarnTest < Minitest::Test
  def test_default_port_is_clean
    assert_nil Yamine::ProxyControl.port_notice(443, true)
    assert_nil Yamine::ProxyControl.port_notice(80, false)
  end

  def test_non_default_port_explains_the_downgrade
    notice = Yamine::ProxyControl.port_notice(1355, true)

    refute_nil notice
    assert_match(/:1355/, notice)
    assert_match(/yamine setup/, notice)
  end

  def test_default_port_predicate
    assert Yamine::ProxyControl.default_port?(443, true)
    assert Yamine::ProxyControl.default_port?(80, false)
    refute Yamine::ProxyControl.default_port?(1355, true)
    # 443 on plain http is NOT the default for that scheme.
    refute Yamine::ProxyControl.default_port?(443, false)
  end

  def test_warning_renders_as_warn_not_ok_and_does_not_fail
    checks = [
      Yamine::Doctor::Check.new(name: "proxy", ok: true, warn: true,
        message: "listening on port 1355 — every URL carries :1355"),
      Yamine::Doctor::Check.new(name: "ca", ok: true, message: "CA trusted")
    ]
    out = StringIO.new
    failed = Yamine::Doctor.print(checks, out: out)

    assert_equal 0, failed, "a warning must not affect the exit status"
    assert_match(/\[warn\] proxy/, out.string)
    assert_match(/\[ok\] ca/, out.string)
  end

  def test_json_includes_warn_flag
    checks = [Yamine::Doctor::Check.new(name: "proxy", ok: true, warn: true,
      message: "port 1355")]
    out = StringIO.new
    Yamine::Doctor.print(checks, out: out, json: true)
    payload = JSON.parse(out.string)

    assert payload["checks"].first["warn"]
    assert_equal 1, payload["warnings"]
    assert_equal 0, payload["failed"]
  end

  def test_failure_still_fails
    checks = [Yamine::Doctor::Check.new(name: "proxy", ok: false,
      message: "not running")]
    out = StringIO.new
    failed = Yamine::Doctor.print(checks, out: out)

    assert_equal 1, failed
    assert_match(/\[FAIL\]/, out.string)
  end
end

# Boot phase events used to be computed and discarded (opts[:events] was
# never set), so a 2-minute healthcheck phase looked like a hang. The
# sink is now wired through, and the human rendering is one line per
# phase.
class LogReportTest < Minitest::Test
  def test_human_renders_phase_line
    out = StringIO.new
    sink = Yamine::Log::Report::Human.new(out)
    event = Yamine::Readiness::Event.new(phase: :process, action: "web",
      status: "ok", duration_ms: 2223, detail: "healthcheck /up returned 2xx-3xx")

    sink.event(event)

    assert_equal "  [web] ok (2.2s) healthcheck /up returned 2xx-3xx\n", out.string
  end

  def test_human_formats_sub_second_durations
    out = StringIO.new
    sink = Yamine::Log::Report::Human.new(out)
    event = Yamine::Readiness::Event.new(phase: :deps, action: "deps",
      status: "ok", duration_ms: 42, detail: nil)

    sink.event(event)

    assert_equal "  [deps] ok (0ms)\n", out.string
  end

  def test_human_note
    out = StringIO.new
    Yamine::Log::Report::Human.new(out).note("[db] myapp_development")

    assert_equal "  [db] myapp_development\n", out.string
  end

  def test_json_emits_one_object_per_event
    out = StringIO.new
    sink = Yamine::Log::Report::Json.new(out)
    sink.event(Yamine::Readiness::Event.new(phase: :deps, action: "deps",
      status: "ok", duration_ms: 10, detail: "dependencies satisfied"))
    sink.note("hello")

    lines = out.string.lines
    assert_equal 2, lines.length
    assert_equal "deps", JSON.parse(lines[0])["phase"]
    assert_equal "hello", JSON.parse(lines[1])["note"]
  end

  # stdout is block-buffered when piped, which is how agents read the
  # --json stream: without a per-line flush the progress events stay in
  # the buffer until it fills or the process exits, so a slow boot looks
  # frozen — the exact failure the stream exists to prevent.
  def test_json_flushes_each_line
    io = FlushSpy.new
    sink = Yamine::Log::Report::Json.new(io)
    sink.event(Yamine::Readiness::Event.new(phase: :process, action: "web",
      status: "ok", duration_ms: 5, detail: nil))
    sink.note("second")

    assert_equal 2, io.flushes, "each emitted line must be flushed"
  end

  # An IO that records how often it was flushed.
  class FlushSpy
    attr_reader :flushes

    def initialize
      @flushes = 0
      @buffer = +""
    end

    def puts(line)
      @buffer << line << "\n"
    end

    def flush
      @flushes += 1
    end
  end

  def test_phase_reports_to_sink
    out = StringIO.new
    sink = Yamine::Log::Report::Human.new(out)
    event = Yamine::Readiness.phase(:deps, "deps", sink: sink) { "dependencies satisfied" }

    assert_equal "ok", event.status
    assert_match(/\[deps\] ok/, out.string)
    assert_match(/dependencies satisfied/, out.string)
  end

  def test_phase_silent_without_sink
    event = Yamine::Readiness.phase(:deps, "deps") { "fine" }

    assert_equal "ok", event.status
  end
end

# The --json contract: stdout carries the machine-readable stream and
# nothing else. Two separate leaks have been caught here — narrative
# lines from the boot banner, and "Starting proxy..." printed before the
# reporter is even installed — so the contract is pinned rather than
# assumed.
class JsonStdoutContractTest < Minitest::Test
  # Every writer in the boot path must route through `say`, which sends
  # narration to stderr when json is on.
  def test_say_routes_to_stderr_in_json_mode
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    Yamine::CLI::BootCommand.send(:say, { json: true }, "narrative")
    $stdout, $stderr = orig_out, orig_err

    assert_empty out.string, "json mode must keep stdout clean"
    assert_equal "narrative\n", err.string
  end

  def test_say_routes_to_stdout_for_humans
    out = StringIO.new
    orig_out = $stdout
    $stdout = out
    Yamine::CLI::BootCommand.send(:say, {}, "narrative")
    $stdout = orig_out

    assert_equal "narrative\n", out.string
  end

  # ensure_proxy! runs before the reporter exists; in json mode its one
  # progress line must still avoid stdout.
  def test_ensure_proxy_narration_avoids_stdout_in_json_mode
    Yamine::ProxyControl.stubs(:listening?).returns(false)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::ProxyControl.stubs(:spawn_daemon).returns(123)
    ctx = Yamine::CLI::Context.new
    # interactive? so the unprivileged-start branch runs: the alternative
    # is the deliberate `exit 1` for a non-interactive privileged port,
    # which would take the test runner down with it.
    ctx.stubs(:interactive?).returns(true)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      Yamine::CLI::BootCommand.send(:ensure_proxy!, ctx, json: true)
    ensure
      $stdout, $stderr = orig_out, orig_err
    end

    assert_empty out.string, "the proxy progress line must not break the JSON stream"
    assert_match(/Starting proxy/, err.string)
  end
end

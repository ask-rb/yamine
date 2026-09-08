# frozen_string_literal: true

require_relative "test_helper"
require "json"

class JsonOutputTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args)
    out = StringIO.new
    orig = $stdout
    $stdout = out
    code = begin
      Yamine::CLI.run(args)
    rescue SystemExit => e
      e.status
    end
    [code, out.string]
  ensure
    $stdout = orig
  end

  def test_list_json_stable_keys
    store = Yamine::RouteStore.new(@dir)
    store.add_route("a.localhost", "127.0.0.1:4001", 0, kind: "tcp")
    code, out = run_cli("list", "--json")
    assert_equal 0, code
    parsed = JSON.parse(out)
    entry = parsed["routes"].first
    %w[hostname url target kind pid supervised alive].each do |key|
      assert entry.key?(key), "list --json entry missing #{key}"
    end
    assert_equal "a.localhost", entry["hostname"]
  end

  def test_list_json_empty
    _code, out = run_cli("list", "--json")
    assert_equal [], JSON.parse(out)["routes"]
  end

  def test_status_json_explicit_nils
    app_dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(app_dir, "config"))
    File.write(File.join(app_dir, "config", "local.yml"),
      "service: myapp\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    code, out = nil, nil
    Dir.chdir(app_dir) do
      code, out = run_cli("status", "--json")
    end
    assert_equal 0, code
    parsed = JSON.parse(out)
    assert_nil parsed["variant"]
    assert_nil parsed["variant_source"]
    assert_equal "myapp", parsed["app"]
    assert parsed.key?("framework")
  ensure
    FileUtils.remove_entry(app_dir) if app_dir
  end

  def test_status_prose_no_dash_source
    app_dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(app_dir, "config"))
    File.write(File.join(app_dir, "config", "local.yml"),
      "service: myapp\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    _code, out = nil, nil
    Dir.chdir(app_dir) do
      _code, out = run_cli("status")
    end
    refute_includes out, "(from -)"
    assert_includes out, "variant:"
  ensure
    FileUtils.remove_entry(app_dir) if app_dir
  end

  def test_doctor_json_counts
    code, out = run_cli("doctor", "--json")
    parsed = JSON.parse(out)
    assert parsed.key?("checks")
    assert parsed.key?("failed")
    assert_equal parsed["failed"].zero?, code.zero?
    names = parsed["checks"].map { |c| c["name"] }
    assert_includes names, "disk"
    assert_includes names, "state"
  end
end

class LogRotationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_rotates_oversize_log
    path = File.join(@dir, "proxy.log")
    File.write(path, "x" * 100)
    Yamine::Log.rotate(path, max_bytes: 10)
    assert File.file?("#{path}.1")
    refute File.file?(path)
    assert_equal "x" * 100, File.read("#{path}.1")
  end

  def test_leaves_small_log_alone
    path = File.join(@dir, "proxy.log")
    File.write(path, "hi")
    Yamine::Log.rotate(path, max_bytes: 10_000)
    assert File.file?(path)
    refute File.file?("#{path}.1")
  end

  def test_open_append_rotates_first
    path = File.join(@dir, "app.log")
    File.write(path, "y" * 100)
    f = Yamine::Log.open_append(path, max_bytes: 10)
    f.write("new\n")
    f.close
    assert_equal "new\n", File.read(path)
    assert_equal "y" * 100, File.read("#{path}.1")
  end

  def test_disk_usage_and_human_bytes
    File.write(File.join(@dir, "a.log"), "12345")
    assert_equal 5, Yamine::Log.disk_usage(@dir)
    assert_equal "5 B", Yamine::Log.human_bytes(5)
    assert_equal "2.0 KB", Yamine::Log.human_bytes(2048)
    assert_equal "3.0 MB", Yamine::Log.human_bytes(3 * 1024 * 1024)
  end

  def test_doctor_disk_warns_on_bloat
    store = Yamine::RouteStore.new(@dir)
    File.write(File.join(@dir, "proxy.log"), "z" * 10)
    check = Yamine::Doctor.check_disk(store)
    assert check.ok
    assert_includes check.message, "B"
  end
end

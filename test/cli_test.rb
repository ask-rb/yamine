# frozen_string_literal: true

require_relative "test_helper"

# CLI smoke tests: --help, --version, get, list, doctor, kamal, alias.
# Full boot paths (managed/run) are covered by manual QA; these pin the
# read-only surface agents depend on. DNS is stubbed: real resolution
# has no timeout guarantees in sandboxed CI.
class CLITest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    Yamine::Hosts.stubs(:resolution).returns(ok: [], warn: [], fail: [])
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = begin
      Yamine::CLI.run(args)
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end

  def test_help
    code, out = run_cli("--help")
    assert_equal 0, code
    assert_includes out, "yamine"
  end

  def test_version
    code, out = run_cli("--version")
    assert_equal 0, code
    assert_includes out, Yamine::VERSION
  end

  def test_get_prints_url
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"),
      "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    Dir.chdir(@dir) do
      c, o = run_cli("get", "backend")
      assert_equal 0, c
      assert_includes o, "backend.localhost"
    end
  end

  def test_list_empty
    code, out = run_cli("list")
    assert_equal 0, code
    assert_includes out, "No active routes"
  end

  def test_alias_and_list_and_remove
    run_cli("alias", "dockerapp", "8080")
    _c, out = run_cli("list")
    assert_includes out, "dockerapp.localhost"
    assert_includes out, "127.0.0.1:8080"
    run_cli("alias", "--remove", "dockerapp")
    _c, out = run_cli("list")
    assert_includes out, "No active routes"
  end

  def test_doctor_reports_proxy_down_but_passes_dns
    code, out = run_cli("doctor")
    assert_equal 1, code
    assert_includes out, "proxy"
    assert_includes out, "[ok] dns"
  end

  def test_kamal_snippet_resolves_app_from_flag
    code, out = run_cli("kamal", "fix-ui", "--app", "myapp",
      "--domain", "preview.example.com")
    assert_equal 0, code
    assert_includes out, "myapp-fix-ui.preview.example.com"
  end

  def test_kamal_snippet_inherits_app_from_directory
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"),
      "service: myapp\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    Dir.chdir(@dir) do
      code, out = run_cli("kamal", "demo")
      assert_equal 0, code
      assert_match(/myapp-demo\.preview\.example\.com/, out)
    end
  end

  def test_get_inherits_variant_from_env
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"),
      "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    ENV["YAMINE_VARIANT"] = "fix-ui"
    Dir.chdir(@dir) do
      c, o = run_cli("get", "backend")
      assert_equal 0, c
      assert_includes o, "fix-ui.backend.localhost"
    end
  ensure
    ENV.delete("YAMINE_VARIANT")
  end

  def test_alias_accepts_full_hostname
    code, out = run_cli("alias", "web.preview.example.com", "9292")
    assert_equal 0, code
    _c, out = run_cli("list")
    assert_includes out, "web.preview.example.com"
  end

  def test_alias_uses_yamine_tld
    ENV["YAMINE_TLD"] = "preview.example.com"
    run_cli("alias", "dockerapp", "8080")
    _c, out = run_cli("list")
    assert_includes out, "dockerapp.preview.example.com"
  ensure
    ENV.delete("YAMINE_TLD")
  end

  def test_unknown_flag_errors
    code, _out = run_cli("run", "--bogus")
    assert_equal 1, code
  end

  def test_worktree_info_shows_branch_and_path
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "app")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q", "-b", "master",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.email", "t@t.t",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.name", "t",
        out: File::NULL, err: File::NULL)
      File.write(File.join(repo, "README.md"), "# app\n")
      system("git", "-C", repo, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "commit", "-qm", "init",
        out: File::NULL, err: File::NULL)
      wt_path = File.join(tmp, "app-wip")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "wip", wt_path,
        out: File::NULL, err: File::NULL)

      Dir.chdir(repo) do
        code, out, = run_cli("worktree", "info", "wip")
        assert_equal 0, code
        assert_includes out, "branch     wip"
        assert_includes out, "path"
        assert_includes out, "HEAD"
        assert_includes out, "dirty      no"
        assert_includes out, "merged"
      end
    end
  end

  def test_worktree_info_json_output
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "app")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q", "-b", "master",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.email", "t@t.t",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.name", "t",
        out: File::NULL, err: File::NULL)
      File.write(File.join(repo, "README.md"), "# app\n")
      system("git", "-C", repo, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "commit", "-qm", "init",
        out: File::NULL, err: File::NULL)
      wt_path = File.join(tmp, "app-wip")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "wip", wt_path,
        out: File::NULL, err: File::NULL)

      Dir.chdir(repo) do
        code, out, = run_cli("worktree", "info", "wip", "--json")
        assert_equal 0, code
        require "json"
        parsed = JSON.parse(out)
        assert_equal "wip", parsed["branch"]
        assert_equal false, parsed["dirty"]
        assert parsed.key?("merged")
        assert parsed.key?("head")
        assert parsed.key?("author")
        assert parsed.key?("date")
      end
    end
  end

  def test_worktree_info_not_found_errors
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "app")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q", "-b", "master",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.email", "t@t.t",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.name", "t",
        out: File::NULL, err: File::NULL)
      File.write(File.join(repo, "README.md"), "# app\n")
      system("git", "-C", repo, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "commit", "-qm", "init",
        out: File::NULL, err: File::NULL)

      Dir.chdir(repo) do
        code, _out, err = run_cli("worktree", "info", "nonexistent")
        assert_equal 1, code
        assert_includes err, "no worktree named"
      end
    end
  end

  def test_worktree_info_missing_name_errors
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "app")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q", "-b", "master",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.email", "t@t.t",
        out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "config", "user.name", "t",
        out: File::NULL, err: File::NULL)
      File.write(File.join(repo, "README.md"), "# app\n")
      system("git", "-C", repo, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "commit", "-qm", "init",
        out: File::NULL, err: File::NULL)

      Dir.chdir(repo) do
        code, _out, err = run_cli("worktree", "info")
        assert_equal 1, code
        assert_includes err, "Usage:"
      end
    end
  end
end

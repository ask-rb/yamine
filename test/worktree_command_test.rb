# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"

# The worktree lifecycle commands, against real temporary git
# repositories. The safety rails are the point: the main checkout is
# untouchable, dirty worktrees are never auto-cleaned, unmerged
# branches survive every path except `remove --force`, and a failed
# database drop aborts before the directory is removed.
#
# Hosts.sync is stubbed in every class (its target is the real
# /etc/hosts) and BootCommand.setup_database is stubbed in the boot
# paths (its target is a database server). DATABASE_URL is scrubbed so
# a shell export can never point a test at a real server.
class WorktreeCommandTest < Minitest::Test
  def setup
    # realpath: git reports macOS temp paths as /private/var/... — the
    # porcelain output must match the paths the tests assert on.
    @root = File.realpath(Dir.mktmpdir)
    @state = File.join(@root, "state")
    @orig_state = ENV["YAMINE_STATE_DIR"]
    @orig_dburl = ENV.delete("DATABASE_URL")
    ENV["YAMINE_STATE_DIR"] = @state
    @app = make_app(File.join(@root, "smokeapp"))
    Yamine::Hosts.stubs(:sync).returns(true)
    Yamine::CLI::BootCommand.stubs(:setup_database).returns([true, nil])
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["DATABASE_URL"] = @orig_dburl if @orig_dburl
    FileUtils.remove_entry(@root)
  end

  def run_cli(*args, chdir: @app)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Dir.chdir(chdir) do
        Yamine::CLI.run(["worktree", *args].map(&:to_s))
      end
    rescue SystemExit => e
      e.status
    end
    [code || 0, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def make_app(dir)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) do
      system("git", "init", "-q", "-b", "master", out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "t@t.t")
      system("git", "config", "user.name", "t")
      FileUtils.mkdir_p("config")
      File.write("config/local.yml", <<~YML)
        service: smokeapp
        proxy:
          tld: localhost
        processes:
          web:
            cmd: puma
            proxy: true
        env:
          clear:
            DATABASE_URL: sqlite3:storage/dev.sqlite3
      YML
      File.write("config/local.secrets", "SECRET_KEY=abc\n")
      File.write("README.md", "# smokeapp\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "init", out: File::NULL, err: File::NULL)
    end
    dir
  end

  def in_app(*args)
    Dir.chdir(@app) { yield }
  end

  def worktree_path(name)
    File.join(@root, "smokeapp-#{name}")
  end

  def claims
    JSON.parse(File.read(File.join(@state, "databases.json")))
  rescue SystemCallError, JSON::ParserError
    {}
  end

  # ── add ─────────────────────────────────────────────────────────────

  def test_add_creates_a_bootable_worktree
    code, out, = run_cli("add", "feature/login")

    assert_equal 0, code, out
    assert File.directory?(worktree_path("feature-login"))
    # The per-checkout config git does not carry came along.
    assert File.file?(File.join(worktree_path("feature-login"), "config", "local.yml"))
    assert File.file?(File.join(worktree_path("feature-login"), "config", "local.secrets"))
    # The database claim is recorded before the first boot.
    assert claims.key?("smokeapp_feature_login_development")
    assert_match(%r{https://feature-login\.smokeapp\.localhost}, out)
    assert_match(/yamine start/, out)
  end

  def test_add_honors_dir_and_skips_install_when_asked
    code, out, = run_cli("add", "elsewhere", "--dir", File.join(@root, "custom"), "--no-install")

    assert_equal 0, code, out
    assert File.directory?(File.join(@root, "custom"))
    refute_match(/bundle install/, out)
  end

  def test_add_refuses_the_default_branch
    code, _out, err = run_cli("add", "master")

    refute_equal 0, code
    assert_match(/default branch/, err)
  end

  def test_add_refuses_an_existing_directory
    FileUtils.mkdir_p(worktree_path("taken"))

    code, _out, err = run_cli("add", "taken")

    refute_equal 0, code
    assert_match(/already exists/, err)
  end

  def test_add_surfaces_gits_reason_when_branch_is_taken
    run_cli("add", "dupe", "--dir", File.join(@root, "dupe-one"))

    code, _out, err = run_cli("add", "dupe", "--dir", File.join(@root, "dupe-two"))

    refute_equal 0, code
    assert_match(/git worktree add failed/, err)
  end

  # ── list ────────────────────────────────────────────────────────────

  def test_list_shows_worktrees_with_status
    run_cli("add", "wip")

    code, out, = run_cli("list")

    assert_equal 0, code
    assert_match(%r{main  #{@app}}, out)
    assert_match(/wip  #{worktree_path("wip")}  db smokeapp_wip_development/, out)
  end

  def test_list_reports_gone_claims
    FileUtils.mkdir_p(@state)
    claims_hash = { "gone_db_development" => { "dir" => "/no/such/dir", "claimed_at" => "now" } }
    File.write(File.join(@state, "databases.json"), JSON.generate(claims_hash))

    code, out, = run_cli("list")

    assert_equal 0, code
    assert_match(/gone_db_development  \/no\/such\/dir  \(gone\)/, out)
  end

  # ── remove ──────────────────────────────────────────────────────────

  def test_remove_tears_down_a_merged_worktree_completely
    run_cli("add", "done")
    in_app { system("git", "merge", "-q", "done", "-m", "merge", out: File::NULL, err: File::NULL) }

    code, out, = run_cli("remove", "done")

    assert_equal 0, code, out
    refute File.directory?(worktree_path("done"))
    assert_empty claims, "the database claim is forgotten"
    assert_match(/deleted branch done/, out)
  end

  def test_remove_keeps_an_unmerged_branch
    run_cli("add", "wip")
    Dir.chdir(worktree_path("wip")) do
      File.write("README.md", "work\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "work", out: File::NULL, err: File::NULL)
    end

    code, out, = run_cli("remove", "wip")

    assert_equal 0, code, out
    refute File.directory?(worktree_path("wip"))
    in_app { assert system("git", "rev-parse", "--verify", "--quiet", "refs/heads/wip", out: File::NULL, err: File::NULL) }
    assert_match(/kept branch wip/, out)
  end

  def test_remove_refuses_the_main_checkout
    code, _out, err = run_cli("remove", "main")

    refute_equal 0, code
    assert_match(/no worktree named/, err)
  end

  def test_remove_names_unknown_worktrees
    code, _out, err = run_cli("remove", "ghost")

    refute_equal 0, code
    assert_match(/no worktree named/, err)
  end

  def test_remove_refuses_dirty_worktrees_without_force
    run_cli("add", "dirty")
    File.write(File.join(worktree_path("dirty"), "README.md"), "uncommitted\n")

    code, _out, err = run_cli("remove", "dirty")

    refute_equal 0, code
    assert File.directory?(worktree_path("dirty"))
    assert_match(/uncommitted changes/, err)
  end

  def test_remove_force_discards_and_deletes_the_branch
    run_cli("add", "dirty")
    File.write(File.join(worktree_path("dirty"), "README.md"), "uncommitted\n")

    code, out, = run_cli("remove", "dirty", "--force")

    assert_equal 0, code, out
    refute File.directory?(worktree_path("dirty"))
    in_app { refute system("git", "rev-parse", "--verify", "--quiet", "refs/heads/dirty", out: File::NULL, err: File::NULL) }
  end

  def test_remove_stops_live_backends_and_removes_routes
    run_cli("add", "live")
    # Double-fork so the sleeper is reparented: once TERMed it is reaped
    # by init and Process.kill(0) raises ESRCH (a killed *child* would
    # linger as a zombie and still answer kill(0)).
    sleeper = Integer(`/bin/sh -c 'sleep 30 & echo $!'`)
    hostname = "live.smokeapp.localhost"
    entry = {
      "hostname" => hostname, "target" => "127.0.0.1:54321", "kind" => "tcp",
      "pid" => sleeper, "agent" => "tester",
      "spec" => { "dir" => File.realpath(worktree_path("live")) }
    }
    File.write(File.join(@state, "routes.json"), JSON.generate([entry]))
    File.write(File.join(@state, "backend-#{hostname}.pid"), sleeper.to_s)

    code, out, = run_cli("remove", "live")

    assert_equal 0, code, out
    assert_match(/stopped #{hostname}/, out)
    assert_raises(Errno::ESRCH) { Process.kill(0, sleeper) }
    routes = JSON.parse(File.read(File.join(@state, "routes.json")))
    refute routes.any? { |r| r["hostname"] == hostname }
    refute File.file?(File.join(@state, "backend-#{hostname}.pid"))
  end

  def test_remove_aborts_and_keeps_everything_when_the_drop_fails
    pg_app = make_app(File.join(@root, "pgapp"))
    pg_config = File.read(File.join(pg_app, "config", "local.yml"))
      .sub("sqlite3:storage/dev.sqlite3", "postgres://u@127.0.0.1:5432/x_development")
    File.write(File.join(pg_app, "config", "local.yml"), pg_config)
    run_cli("add", "pgwt", chdir: pg_app)
    Yamine::Database.stubs(:drop).returns(:failed)

    code, _out, err = run_cli("remove", "pgwt", chdir: pg_app)

    refute_equal 0, code
    assert File.directory?(File.join(@root, "pgapp-pgwt")), "the worktree survives a failed drop"
    assert claims.key?("pgapp_pgwt_development"), "the claim survives for a retry"
    assert_match(/database drop failed/, err)
  end

  def test_remove_prunes_a_worktree_whose_directory_is_already_gone
    run_cli("add", "lost")
    FileUtils.rm_rf(worktree_path("lost"))

    code, out, = run_cli("remove", "lost")

    assert_equal 0, code, out
    assert_match(/pruned/, out)
    assert_empty claims
    in_app { assert_equal 1, `git worktree list | wc -l`.to_i }
  end

  # ── clean ───────────────────────────────────────────────────────────

  def test_clean_keeps_unmerged_and_dirty_reports_the_reason
    run_cli("add", "wip")
    Dir.chdir(worktree_path("wip")) do
      File.write("README.md", "work\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "work", out: File::NULL, err: File::NULL)
    end
    run_cli("add", "dirty")
    File.write(File.join(worktree_path("dirty"), "README.md"), "uncommitted\n")

    code, out, = run_cli("clean")

    assert_equal 0, code, out
    assert File.directory?(worktree_path("wip"))
    assert File.directory?(worktree_path("dirty"))
    assert_match(/branch not merged into master/, out)
    assert_match(/uncommitted changes are never cleaned automatically/, out)
  end

  def test_clean_removes_merged_worktrees_end_to_end
    run_cli("add", "done")
    in_app { system("git", "merge", "-q", "done", "-m", "merge", out: File::NULL, err: File::NULL) }

    code, out, = run_cli("clean")

    assert_equal 0, code, out
    refute File.directory?(worktree_path("done"))
    assert_empty claims
    assert_match(/removed/, out)
  end

  def test_clean_all_removes_an_unmerged_worktree_but_keeps_its_branch
    run_cli("add", "wip")
    Dir.chdir(worktree_path("wip")) do
      File.write("README.md", "work\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "work", out: File::NULL, err: File::NULL)
    end

    code, out, = run_cli("clean", "--all")

    assert_equal 0, code, out
    refute File.directory?(worktree_path("wip"))
    in_app { assert system("git", "rev-parse", "--verify", "--quiet", "refs/heads/wip", out: File::NULL, err: File::NULL) }
    assert_match(/kept branch wip/, out)
  end

  def test_clean_dry_run_changes_nothing
    run_cli("add", "wip")
    Dir.chdir(worktree_path("wip")) do
      File.write("README.md", "work\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "work", out: File::NULL, err: File::NULL)
    end

    code, out, = run_cli("clean", "--dry-run")

    assert_equal 0, code, out
    assert_match(/would keep/, out)
    assert File.directory?(worktree_path("wip"))
    assert claims.key?("smokeapp_wip_development")
  end

  def test_clean_forgots_orphaned_claims_without_a_server
    run_cli("add", "dropped")
    FileUtils.rm_rf(worktree_path("dropped"))

    code, out, = run_cli("clean")

    assert_equal 0, code, out
    assert_empty claims
    assert_match(/claim forgotten/, out)
    in_app { assert_equal 1, `git worktree list | wc -l`.to_i }
  end

  def test_clean_with_nothing_to_do_says_so
    code, out, = run_cli("clean")

    assert_equal 0, code
    assert_match(/Nothing to clean/, out)
  end
end

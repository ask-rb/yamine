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

  def branch_exists?(name)
    system("git", "-C", @app, "rev-parse", "--verify", "--quiet",
      "refs/heads/#{name}", out: File::NULL, err: File::NULL)
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

  def test_remove_stale_merged_worktree_deletes_the_branch
    run_cli("add", "done")
    in_app { system("git", "merge", "-q", "done", "-m", "merge", out: File::NULL, err: File::NULL) }
    FileUtils.rm_rf(worktree_path("done"))

    code, out, = run_cli("remove", "done")

    assert_equal 0, code, out
    assert_match(/pruned/, out)
    assert_match(/deleted branch done/, out)
    refute branch_exists?("done")
    assert_empty claims
  end

  def test_remove_stale_unmerged_worktree_keeps_the_branch
    run_cli("add", "wip")
    Dir.chdir(worktree_path("wip")) do
      File.write("README.md", "work\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "work", out: File::NULL, err: File::NULL)
    end
    FileUtils.rm_rf(worktree_path("wip"))

    code, out, = run_cli("remove", "wip")

    assert_equal 0, code, out
    assert_match(/pruned/, out)
    assert_match(/kept branch wip/, out)
    assert branch_exists?("wip")
    assert_empty claims
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

  def test_clean_stale_merged_worktree_deletes_the_branch
    run_cli("add", "done")
    in_app { system("git", "merge", "-q", "done", "-m", "merge", out: File::NULL, err: File::NULL) }
    FileUtils.rm_rf(worktree_path("done"))

    code, out, = run_cli("clean")

    assert_equal 0, code, out
    assert_match(/deleted branch done/, out)
    refute branch_exists?("done")
    assert_empty claims
  end

  def test_clean_with_nothing_to_do_says_so
    code, out, = run_cli("clean")

    assert_equal 0, code
    assert_match(/Nothing to clean/, out)
  end
end

# Multi-database worktrees: the app is asked what it has (a fake
# bin/rails that answers the probe like a conforming Rails app), the
# whole set is claimed, suffixed, markered, and dropped as a unit.
class WorktreeMultiDbTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @state = File.join(@root, "state")
    @orig_state = ENV["YAMINE_STATE_DIR"]
    @orig_dburl = ENV.delete("DATABASE_URL")
    ENV["YAMINE_STATE_DIR"] = @state
    @app = make_rails_multi_app(File.join(@root, "multirails"))
    Yamine::Hosts.stubs(:sync).returns(true)
    # These tests exercise the REAL provisioning path; the shared
    # suite stubs setup_database for non-Rails fixtures.
    Yamine::CLI::BootCommand.unstub(:setup_database)
    Yamine::Database.stubs(:exists?).returns(true)
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["DATABASE_URL"] = @orig_dburl if @orig_dburl
    FileUtils.remove_entry(@root)
  end

  # A conforming fake: probe answers base names before the marker
  # exists and suffixed names after — exactly what a database.yml
  # suffix hook produces.
  def make_rails_multi_app(dir)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) do
      system("git", "init", "-q", "-b", "master", out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "t@t.t")
      system("git", "config", "user.name", "t")
      FileUtils.mkdir_p("config")
      FileUtils.mkdir_p("bin")
      File.write("config/application.rb", "module Fake; class Application; end; end\n")
      File.write("config/local.yml", <<~YML)
        service: multirails
        proxy:
          tld: localhost
        processes:
          web:
            cmd: puma
            proxy: true
      YML
      File.write("bin/rails", <<~SH)
        #!/bin/sh
        [ "$1" = "runner" ] || exit 0
        S=""
        [ -f .yamine-db-suffix ] && S=$(cat .yamine-db-suffix)
        if [ "$RAILS_ENV" = "test" ]; then
          # Flat test config: implicitly named "primary" in real Rails.
          printf '%s\\n' "YAMINE_DBS=[{\\"name\\":\\"primary\\",\\"database\\":\\"app_test${S:+_$S}\\",\\"url\\":\\"postgres://u@127.0.0.1:5432/app_test${S:+_$S}\\"}]"
        elif [ -n "$S" ]; then
          printf '%s\\n' "YAMINE_DBS=[{\\"name\\":\\"primary\\",\\"database\\":\\"app_dev_$S\\",\\"url\\":\\"postgres://u@127.0.0.1:5432/app_dev_$S\\"},{\\"name\\":\\"cache\\",\\"database\\":\\"app_dev_cache_$S\\",\\"url\\":\\"postgres://u@127.0.0.1:5432/app_dev_cache_$S\\"}]"
        else
          printf '%s\\n' 'YAMINE_DBS=[{"name":"primary","database":"app_dev","url":"postgres://u@127.0.0.1:5432/app_dev"},{"name":"cache","database":"app_dev_cache","url":"postgres://u@127.0.0.1:5432/app_dev_cache"}]'
        fi
      SH
      File.chmod(0o755, "bin/rails")
      File.write("README.md", "# multirails\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "init", out: File::NULL, err: File::NULL)
    end
    dir
  end

  def run_cli(*args, chdir: @app)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Dir.chdir(chdir) { Yamine::CLI.run(["worktree", *args].map(&:to_s)) }
    rescue SystemExit => e
      e.status
    end
    [code || 0, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def run_db(*args, chdir: @app)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Dir.chdir(chdir) { Yamine::CLI.run(["db", *args].map(&:to_s)) }
    rescue SystemExit => e
      e.status
    end
    [code || 0, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def claims
    JSON.parse(File.read(File.join(@state, "databases.json")))
  rescue SystemCallError, JSON::ParserError
    {}
  end

  def worktree_path(label)
    File.join(@root, "multirails-#{label}")
  end

  def claim_for_label(label)
    dir = File.expand_path(worktree_path(label))
    claims.find { |_, info| info["dir"] == dir }
  end

  def test_add_claims_the_whole_suffixed_set_with_marker
    code, out, err = run_cli("add", "feature")

    assert_equal 0, code, "#{out}\n#{err}"
    key, info = claim_for_label("feature")
    refute_nil key, "a claim exists for the worktree"
    suffix = info["suffix"]
    refute_nil suffix
    assert_equal(
      { "primary" => "app_dev_#{suffix}", "cache" => "app_dev_cache_#{suffix}",
        "test" => "app_test_#{suffix}" },
      info["names"], "the test database joins the claim so teardown can drop it")
    assert_equal "postgres://u@127.0.0.1:5432/app_dev", info.dig("bases", "primary")

    wt = worktree_path("feature")
    assert_equal suffix, Yamine::Database.read_marker(wt), "marker carries the same suffix"
    exclude = File.read(File.join(@app, ".git", "info", "exclude"))
    assert_includes exclude, Yamine::Database::MARKER_FILE

    # Creation ran against every database (exists? stubbed true => none
    # created here), and the conformance proof passed loudly.
    assert_includes out, "database.yml reads .yamine-db-suffix"
    assert_includes out, "db       3 databases:"
    assert_includes out, "app_dev_#{suffix}"
    assert_includes out, "app_dev_cache_#{suffix}"
    assert_includes out, "app_test_#{suffix}"
  end

  def test_add_fails_loudly_when_the_server_cannot_be_reached
    Yamine::Database.unstub(:exists?)
    Yamine::Database.stubs(:exists?).returns(false)
    Yamine::Database.stubs(:ensure_exists).returns(false)

    code, out, err = run_cli("add", "feature")

    refute_equal 0, code, out
    assert_includes err, "could not create"
    assert File.directory?(worktree_path("feature")), "the worktree is kept for a retry"
    _, info = claim_for_label("feature")
    refute_nil info, "the claim is kept — `yamine db create` finishes the job"
  ensure
    Yamine::Database.stubs(:exists?).returns(true)
  end

  def test_add_creates_missing_databases_and_loads_schema
    # First two exists? probes say "missing" (the ensure loop), the
    # post-create re-check says "there" — mocha consumes the values in
    # order and repeats the last.
    Yamine::Database.unstub(:exists?)
    Yamine::Database.stubs(:exists?).returns(false, false, true)
    Yamine::Database.stubs(:ensure_exists).returns(true)
    Yamine::CLI::BootCommand.expects(:run_schema_load).once.returns("loaded schema")

    code, out, err = run_cli("add", "feature")

    assert_equal 0, code, "#{out}\n#{err}"
    _, info = claim_for_label("feature")
    refute_nil info&.dig("names", "primary")
    assert_includes out, "database.yml reads .yamine-db-suffix"
    # The test database was created empty by this pass — prepared so
    # `rails test` runs as-is (fake bin/rails exits 0 for any task).
    assert_includes out, "test database schema ready"
  ensure
    Yamine::Database.unstub(:exists?)
    Yamine::Database.unstub(:ensure_exists)
    Yamine::Database.stubs(:exists?).returns(true)
  end

  def test_non_conforming_app_still_boot_isolated_but_warns
    # A database.yml without the suffix hook: probe post-marker still
    # returns base names. Creation succeeds; the hand-run gap is said
    # out loud at that exact moment.
    File.write(File.join(@app, "bin", "rails"), <<~SH)
      #!/bin/sh
      [ "$1" = "runner" ] || exit 0
      if [ "$RAILS_ENV" = "test" ]; then
        printf '%s\\n' 'YAMINE_DBS=[{"name":"primary","database":"app_test","url":"postgres://u@127.0.0.1:5432/app_test"}]'
      else
        printf '%s\\n' 'YAMINE_DBS=[{"name":"primary","database":"app_dev","url":"postgres://u@127.0.0.1:5432/app_dev"},{"name":"cache","database":"app_dev_cache","url":"postgres://u@127.0.0.1:5432/app_dev_cache"}]'
      fi
    SH
    File.chmod(0o755, File.join(@app, "bin", "rails"))
    Dir.chdir(@app) do
      system("git", "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "commit", "-qm", "nonconf", out: File::NULL, err: File::NULL)
    end

    code, out, err = run_cli("add", "feature")

    assert_equal 0, code, "a non-conforming app still gets a bootable worktree:\n#{out}\n#{err}"
    assert_includes err, "does not read .yamine-db-suffix"
    assert_includes err, "Supervised boots are still isolated via env"
    _, info = claim_for_label("feature")
    refute_nil info, "the claim and marker exist regardless"
  end

  def test_list_and_db_list_show_every_name
    run_cli("add", "feature")
    _, info = claim_for_label("feature")

    code, out, = run_cli("list")
    assert_equal 0, code
    assert_includes out, "db 3 databases"
    info["names"].each_value { |db| assert_includes out, "db: #{db}" }

    code, out, = run_db("list")
    assert_equal 0, code
    info["names"].each_value { |db| assert_includes out, "db: #{db}" }
  end

  def test_remove_drops_every_database_as_a_unit
    run_cli("add", "feature")
    _, info = claim_for_label("feature")
    Yamine::Database.stubs(:drop).returns(:dropped)

    code, out, = run_cli("remove", "feature")

    assert_equal 0, code, out
    info["names"].each_value { |db| assert_includes out, "dropped #{db}" }
    refute claim_for_label("feature"), "the claim is gone"
    refute File.directory?(worktree_path("feature"))
  end

  def test_one_failed_drop_aborts_the_whole_teardown
    run_cli("add", "feature")
    key, info = claim_for_label("feature")
    Yamine::Database.stubs(:drop).returns(:failed)

    code, _out, err = run_cli("remove", "feature")

    refute_equal 0, code
    assert File.directory?(worktree_path("feature")), "the worktree survives a failed drop"
    assert claims.key?(key), "the claim — and with it every database name — is kept"
    assert_match(/database drop failed/, err)
  end

  def test_orphaned_worktree_drops_the_whole_set_without_the_app
    # rm -rf the directory: the config is gone, so drops must work
    # from the claim's own names and server coordinates alone — no
    # probe, no boot, no bundle.
    run_cli("add", "feature")
    key, info = claim_for_label("feature")
    FileUtils.rm_rf(worktree_path("feature"))
    Yamine::Database.stubs(:drop).returns(:dropped)

    code, out, = run_cli("remove", "feature")

    assert_equal 0, code, out
    info["names"].each_value { |db| assert_includes out, "dropped #{db}" }
    refute claims.key?(key)
    assert_includes out, "pruned"
  end

  def test_db_create_in_a_worktree_is_the_same_provisioning
    run_cli("add", "feature")
    key, info = claim_for_label("feature")
    expect_names = info["names"].dup

    # Simulate a claim that lost a database (an app that grew one):
    # drop "names"; `db create` inside the worktree re-probes and
    # heals it. The marker is already in place there, so this also
    # pins the no-double-suffix rule.
    map = claims
    map[key].delete("names")
    File.write(File.join(@state, "databases.json"), JSON.pretty_generate(map))

    code, out, err = run_db("create", chdir: worktree_path("feature"))
    assert_equal 0, code, "#{out}\n#{err}"
    assert_includes out, "Database set ready (3)"
    healed = claims[key]["names"]
    assert_equal expect_names, healed, "re-probe derives the identical set"
  end

  def test_db_create_on_the_main_checkout_keeps_base_names
    code, out, err = run_db("create")

    assert_equal 0, code, "#{out}\n#{err}"
    assert_includes out, "Base databases ready (2)"
    assert_includes out, "app_dev"
    refute_includes out, "app_dev_multirails", "the main checkout never gets a suffix"
    _, info = claims.find { |k, v| v["dir"] == File.expand_path(@app) }
    refute info&.key?("names"), "no multi claim is written for main"
  end

  def test_db_describe_asks_the_app_and_masks_nothing_without_password
    code, out, err = run_db("describe")
    assert_equal 0, code, err
    assert_includes out, "primary (server)"
    assert_includes out, "database: app_dev"
    assert_includes out, "cache (server)"
  end

  def test_db_drop_by_inner_name_drops_the_whole_claim
    run_cli("add", "feature")
    key, info = claim_for_label("feature")
    FileUtils.rm_rf(worktree_path("feature"))
    Yamine::Database.stubs(:drop).returns(:dropped)

    # Identifying by one actual database name must resolve to its
    # claim — the set is the unit.
    code, out, = run_db("drop", info["names"]["cache"])

    assert_equal 0, code, out
    info["names"].each_value { |db| assert_includes out, "dropped #{db}" }
    refute claims.key?(key)
  end
end

class WorktreeLegacyOrphanTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @state = File.join(@root, "state")
    @orig_state = ENV["YAMINE_STATE_DIR"]
    @orig_dburl = ENV.delete("DATABASE_URL")
    ENV["YAMINE_STATE_DIR"] = @state
    @app = File.join(@root, "legacyapp")
    FileUtils.mkdir_p(@app)
    Dir.chdir(@app) do
      system("git", "init", "-q", "-b", "master", out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "t@t.t")
      system("git", "config", "user.name", "t")
      FileUtils.mkdir_p("config")
      # No DATABASE_URL anywhere — a credentials-style app's config.
      File.write("config/local.yml", <<~YML)
        service: legacyapp
        proxy:
          tld: localhost
        processes:
          web:
            cmd: puma
            proxy: true
      YML
      File.write("README.md", "# legacy\n")
      system("git", "add", "-A")
      system("git", "commit", "-qm", "init", out: File::NULL, err: File::NULL)
    end
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
      Dir.chdir(chdir) { Yamine::CLI.run(["worktree", *args].map(&:to_s)) }
    rescue SystemExit => e
      e.status
    end
    [code || 0, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def claims
    JSON.parse(File.read(File.join(@state, "databases.json")))
  rescue SystemCallError, JSON::ParserError
    {}
  end

  # A legacy claim whose app never declared a template (credentials
  # apps pre-multi-database) can never be resolved by any future
  # command — erroring forever made `clean` permanently red for
  # everyone. It must be forgotten, with the database name said out
  # loud so a real leftover stays droppable by hand.
  def test_orphaned_templateless_claim_is_forgotten_not_blocking
    code, out, err = run_cli("add", "lost")
    assert_equal 0, code, out
    FileUtils.rm_rf(File.join(@root, "legacyapp-lost"))
    assert claims.key?("legacyapp_lost_development")

    code, out, err = run_cli("clean", "--all")

    assert_equal 0, code, "clean must pass despite an unresolvable legacy claim:\n#{err}"
    assert_match(/cannot reach legacyapp_lost_development; claim forgotten/, err)
    assert_match(/drop it manually/, err)
    assert_empty claims, "the stuck claim is gone — next clean starts clean"
    assert_match(/Cleaned/, out)
  end
end

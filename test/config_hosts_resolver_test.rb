# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "config"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_yml(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_loads_service
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    config = Yamine::Config.load(@dir)
    assert_equal "myapp", config.service
  end

  def test_invalid_yml_raises
    File.write(File.join(@dir, "config", "local.yml"), ": [bad")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_missing_service_raises
    write_yml("proxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_empty_processes_raises
    write_yml("service: x\nprocesses: {}")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_missing_config_returns_nil
    assert_nil Yamine::Config.load(@dir)
  end
end

class ResolverTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "config"))
    @orig = ENV.to_h
  end

  def teardown
    ENV.replace(@orig)
    FileUtils.remove_entry(@dir)
  end

  def write_yml(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_service_from_config
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "myapp", r.app
    assert_equal "localhost", r.tld
  end

  def test_tld_from_config
    write_yml("service: x\nproxy:\n  tld: preview.example.com\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "preview.example.com", r.tld
  end

  def test_host_from_config
    write_yml("service: x\nproxy:\n  host: myapp.prod.example.com\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "myapp.prod.example.com", r.host
  end

  def test_hostnames_compose_from_config
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true\n  api:\n    cmd: api\n    proxy: true\n  worker:\n    cmd: j\n    proxy: false")
    r = Yamine::Resolver.resolve(@dir)
    hostnames = Yamine::Resolver.hostnames(r)
    assert_includes hostnames, "myapp.localhost"
    assert_includes hostnames, "api.myapp.localhost"
    refute_includes hostnames, "worker.myapp.localhost"
  end

  def test_missing_config_raises
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Resolver.resolve(@dir)
    end
    assert_match(/yamine init/, err.message)
  end

  # ── Variant: a hostname label, not a config file ────────────────────
  #
  # Two axes that used to be one. `overlay` is an explicit
  # config/local.<name>.yml to merge; `variant` is the leading hostname
  # label. Only an explicit --variant / YAMINE_VARIANT sets the overlay,
  # so a branch name can never select config on its own.

  def test_variant_prefixes_every_hostname
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true\n  api:\n    cmd: api\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir, variant: "fix-ui")
    hostnames = Yamine::Resolver.hostnames(r)
    assert_includes hostnames, "fix-ui.myapp.localhost"
    assert_includes hostnames, "fix-ui.api.myapp.localhost"
  end

  def test_variant_merges_its_overlay_when_asked_explicitly
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    File.write(File.join(@dir, "config", "local.staging.yml"),
      "proxy:\n  tld: staging.example.com\n")
    r = Yamine::Resolver.resolve(@dir, variant: "staging")
    assert_equal "staging.example.com", r.tld
    assert_equal "staging", r.overlay
    assert_includes Yamine::Resolver.hostnames(r), "staging.myapp.staging.example.com"
  end

  def test_explicit_host_is_never_rewritten_by_a_variant
    write_yml("service: x\nproxy:\n  host: myapp.prod.example.com\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir, variant: "fix-ui")
    assert_equal ["myapp.prod.example.com"], Yamine::Resolver.hostnames(r)
  end

  # The safety property the split exists for: a worktree whose branch
  # happens to match a file on disk must not change the config. Only an
  # explicit --variant / YAMINE_VARIANT merges an overlay.
  def test_worktree_branch_does_not_merge_a_matching_overlay_file
    repo = File.join(@dir, "repo")
    FileUtils.mkdir_p(repo)
    write_yml_at(repo, "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "t@t.t")
    git(repo, "config", "user.name", "t")
    git(repo, "commit", "-q", "--allow-empty", "-m", "init")

    work = File.join(@dir, "work")
    unless system("git", "-C", repo, "worktree", "add", work, "-b", "feature-login",
      out: File::NULL, err: File::NULL)
      skip "git worktree unsupported here"
    end
    write_yml_at(work, "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    File.write(File.join(work, "config", "local.feature-login.yml"),
      "proxy:\n  tld: hijacked.example.com\n")

    r = Yamine::Resolver.resolve(work)
    assert_equal "feature-login", r.variant, "the branch still names the hostname"
    assert_nil r.overlay, "only an explicit variant may merge a file"
    assert_equal "localhost", r.tld, "the hijacking overlay must not apply"
  end

  def test_no_variant_leaves_hostnames_bare
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_nil r.variant
    assert_nil r.overlay
    assert_equal ["myapp.localhost"], Yamine::Resolver.hostnames(r)
  end

  def write_yml_at(dir, content)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "local.yml"), content)
  end

  def git(dir, *args)
    raise "git #{args.join(" ")} failed" unless system("git", "-C", dir, *args)
  end
end

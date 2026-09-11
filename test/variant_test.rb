# frozen_string_literal: true

require_relative "test_helper"

class VariantTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_env = ENV.to_h
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV.replace(@orig_env)
  end

  def test_explicit_flag_wins
    variant, source = Yamine::Variant.resolve(@dir, explicit: "Demo_1")
    assert_equal "demo-1", variant
    assert_equal "flag", source
  end

  def test_env_var
    ENV["YAMINE_VARIANT"] = "staging"
    variant, source = Yamine::Variant.resolve(@dir)
    assert_equal "staging", variant
    assert_equal "YAMINE_VARIANT", source
  end

  def test_no_git_no_variant
    assert_nil Yamine::Variant.resolve(@dir)
  end

  def test_main_branch_never_prefixes
    init_repo(@dir, branch: "main")
    assert_nil Yamine::Variant.resolve(@dir, use_branch: true)
  end

  def test_feature_branch_prefixes_only_when_opted_in
    init_repo(@dir, branch: "feature/login-flow")
    assert_nil Yamine::Variant.resolve(@dir)
    variant, source = Yamine::Variant.resolve(@dir, use_branch: true)
    # The whole branch, not its last segment: `feature/login-flow` and
    # `bugfix/login-flow` must not share a hostname.
    assert_equal "feature-login-flow", variant
    assert_equal "git branch", source
  end

  def test_detached_head_no_variant
    init_repo(@dir, branch: "main")
    system("git", "-C", @dir, "checkout", "-q", "--detach", "HEAD",
      out: File::NULL, err: File::NULL)
    assert_nil Yamine::Variant.resolve(@dir, use_branch: true)
  end

  def test_linked_worktree_gets_prefix
    main = File.join(@dir, "main")
    FileUtils.mkdir_p(main)
    init_repo(main, branch: "main")
    work = File.join(@dir, "work")
    ok = system("git", "-C", main, "worktree", "add", work, "-b", "fix-ui",
      out: File::NULL, err: File::NULL)
    skip "git worktree unsupported here" unless ok

    variant, source = Yamine::Variant.resolve(work)
    assert_equal "fix-ui", variant
    assert_equal "git worktree", source

    # Main checkout keeps the bare name.
    assert_nil Yamine::Variant.resolve(main)
  end

  def test_apply
    assert_equal "fix.myapp", Yamine::Variant.apply("myapp", "fix")
    assert_equal "myapp", Yamine::Variant.apply("myapp", nil)
  end

  # ── Branch labels ───────────────────────────────────────────────────
  #
  # The label is the whole branch, not its last path segment: two
  # worktrees of `feature/login` and `bugfix/login` are different
  # checkouts and must not answer on one hostname.

  def test_branch_label_keeps_the_whole_branch
    assert_equal "feature-login", Yamine::Variant.branch_to_prefix("feature/login")
    assert_equal "bugfix-login", Yamine::Variant.branch_to_prefix("bugfix/login")
  end

  def test_sibling_branches_do_not_collide
    refute_equal Yamine::Variant.branch_to_prefix("feature/login"),
      Yamine::Variant.branch_to_prefix("bugfix/login")
  end

  def test_default_branches_never_prefix
    assert_nil Yamine::Variant.branch_to_prefix("main")
    assert_nil Yamine::Variant.branch_to_prefix("master")
    assert_nil Yamine::Variant.branch_to_prefix("HEAD")
  end

  def test_overlong_branch_label_still_resolves
    branch = "feature/#{"very-long-" * 10}name"
    label = Yamine::Variant.branch_to_prefix(branch)
    assert label.length <= 63, "a DNS label cannot exceed 63 chars: #{label}"
    assert_match(/\A[a-z0-9-]+\z/, label)
  end

  # ── Detached worktrees ──────────────────────────────────────────────
  #
  # A detached HEAD has no branch, so the directory names it — the same
  # identity the per-worktree database uses. Without a fallback such a
  # worktree would take the bare app name and collide with the main
  # checkout's running app.

  def test_detached_worktree_falls_back_to_directory
    main = File.join(@dir, "main")
    FileUtils.mkdir_p(main)
    init_repo(main, branch: "main")
    work = File.join(@dir, "ui-tweak")
    ok = system("git", "-C", main, "worktree", "add", "--detach", work,
      out: File::NULL, err: File::NULL)
    skip "git worktree unsupported here" unless ok

    variant, source = Yamine::Variant.resolve(work)
    assert_equal "ui-tweak", variant
    assert_equal "git worktree", source
  end

  private

  # ── End to end: a worktree serves its own hostname ──────────────────
  #
  # The resolver is where the worktree prefix has to land: `hostnames`
  # feeds route registration AND the ownership gate, so a worktree that
  # resolves its own hostname can boot beside the main checkout instead
  # of colliding with it.

  def test_worktree_resolves_its_own_hostname
    main = File.join(@dir, "myapp")
    FileUtils.mkdir_p(main)
    init_repo(main, branch: "main")
    write_app_config(main, service: "myapp")

    work = File.join(@dir, "myapp-ui")
    ok = system("git", "-C", main, "worktree", "add", work, "-b", "ui-onboarding",
      out: File::NULL, err: File::NULL)
    skip "git worktree unsupported here" unless ok
    write_app_config(work, service: "myapp")

    resolved = Yamine::Resolver.resolve(work)
    assert_equal "ui-onboarding", resolved.variant
    assert_includes Yamine::Resolver.hostnames(resolved), "ui-onboarding.myapp.localhost"

    # The main checkout keeps the bare name, which is what lets both run.
    root = Yamine::Resolver.resolve(main)
    assert_nil root.variant
    assert_equal ["myapp.localhost"], Yamine::Resolver.hostnames(root)
  end

  def write_app_config(dir, service:)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "local.yml"), <<~YAML)
      service: #{service}
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
  end

  def init_repo(dir, branch:)
    system("git", "init", "-q", "-b", branch, dir, out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.email", "t@t.t",
      out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.name", "t",
      out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "commit", "-q", "--allow-empty", "-m", "init",
      out: File::NULL, err: File::NULL)
  end
end

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
    assert_equal "login-flow", variant
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

  private

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

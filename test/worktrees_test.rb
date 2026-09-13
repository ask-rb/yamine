# frozen_string_literal: true

require_relative "test_helper"

# Unit tests for the git plumbing behind the worktree commands. The
# porcelain parser is tested against fixture strings; everything else
# runs against real (temporary) git repositories — the whole point of
# this module is to say exactly what git said.
class WorktreesParseTest < Minitest::Test
  def test_parses_main_and_linked_worktrees
    porcelain = <<~PORCELAIN
      worktree /code/app
      HEAD abc123
      branch refs/heads/master

      worktree /code/app-feature
      HEAD def456
      branch refs/heads/feature/login
    PORCELAIN

    entries = Yamine::Worktrees.parse(porcelain)

    assert_equal 2, entries.length
    assert_equal "/code/app", entries[0].path
    assert_equal "master", entries[0].branch
    refute entries[0].detached
    assert_equal "feature/login", entries[1].branch
    assert_equal "def456", entries[1].head
  end

  def test_parses_detached_and_bare_entries
    porcelain = <<~PORCELAIN
      worktree /code/app
      HEAD abc123

      worktree /srv/bare
      bare

      worktree /code/detached
      HEAD 000000
      detached
    PORCELAIN

    entries = Yamine::Worktrees.parse(porcelain)

    assert entries[1].bare
    refute entries[1].detached
    assert_nil entries[2].branch
    assert entries[2].detached
  end

  def test_empty_input_has_no_entries
    assert_empty Yamine::Worktrees.parse("")
  end
end

class WorktreesGitTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @repo = File.join(@dir, "app")
    FileUtils.mkdir_p(@repo)
    git(@repo, "init", "-q", "-b", "master")
    git(@repo, "config", "user.email", "t@t.t")
    git(@repo, "config", "user.name", "t")
    File.write(File.join(@repo, "README.md"), "# app\n")
    git(@repo, "add", "-A")
    git(@repo, "commit", "-qm", "init")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(dir, *args)
    out = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed" unless out
  end

  def test_add_creates_a_new_branch_and_directory
    ok, status = Yamine::Worktrees.add(@repo, "feature/login", File.join(@dir, "app-feature"))

    assert status&.success?, ok
    assert File.directory?(File.join(@dir, "app-feature"))
    assert git_branch_exists?("feature/login")
  end

  def test_add_checks_out_an_existing_branch
    git(@repo, "branch", "existing")

    _out, status = Yamine::Worktrees.add(@repo, "existing", File.join(@dir, "app-existing"))

    assert status&.success?
    assert_equal "existing", Yamine::Worktrees.find(@repo, "app-existing").branch
  end

  def test_add_failure_carries_gits_stderr
    Yamine::Worktrees.add(@repo, "dupe", File.join(@dir, "app-dupe"))

    out, status = Yamine::Worktrees.add(@repo, "dupe", File.join(@dir, "app-dupe-2"))

    refute status&.success?
    assert_match(/already.*checked out|already used/, out)
  end

  def test_list_and_find_by_branch_and_basename
    Yamine::Worktrees.add(@repo, "wip", File.join(@dir, "app-wip"))

    entries = Yamine::Worktrees.list(@repo)

    assert_equal 2, entries.length
    assert entries.first.main?, "git lists the main worktree first"
    assert_equal "wip", Yamine::Worktrees.find(@repo, "wip").branch
    assert_equal "wip", Yamine::Worktrees.find(@repo, "app-wip").branch
    assert_nil Yamine::Worktrees.find(@repo, "nope")
  end

  def test_dirty_detects_uncommitted_changes
    Yamine::Worktrees.add(@repo, "wip", File.join(@dir, "app-wip"))

    refute Yamine::Worktrees.dirty?(File.join(@dir, "app-wip"))
    File.write(File.join(@dir, "app-wip", "README.md"), "changed\n")
    assert Yamine::Worktrees.dirty?(File.join(@dir, "app-wip"))
  end

  def test_merged_distinguishes_merged_from_divergent
    Yamine::Worktrees.add(@repo, "wip", File.join(@dir, "app-wip"))
    wt = File.join(@dir, "app-wip")
    File.write(File.join(wt, "README.md"), "work\n")
    git(wt, "add", "-A")
    git(wt, "commit", "-qm", "work")

    refute Yamine::Worktrees.merged?(@repo, "wip", into: "master"),
      "a branch with its own commit is not merged"

    git(@repo, "merge", "-q", "--no-ff", "wip", "-m", "merge")
    assert Yamine::Worktrees.merged?(@repo, "wip", into: "master")
  end

  def test_merged_is_false_without_a_branch
    refute Yamine::Worktrees.merged?(@repo, nil, into: "master")
  end

  def test_default_branch_prefers_a_local_main_or_master
    assert_equal "master", Yamine::Worktrees.default_branch(@repo)

    git(@repo, "branch", "main")
    assert_equal "main", Yamine::Worktrees.default_branch(@repo)
  end

  def test_remove_and_prune
    path = File.join(@dir, "app-wip")
    Yamine::Worktrees.add(@repo, "wip", path)

    _out, status = Yamine::Worktrees.remove(@repo, path)
    assert status&.success?
    refute File.directory?(path)
    assert_equal 1, Yamine::Worktrees.list(@repo).length
  end

  def test_list_outside_a_repo_is_empty
    assert_empty Yamine::Worktrees.list(@dir)
  end

  private

  def git_branch_exists?(name)
    system("git", "-C", @repo, "rev-parse", "--verify", "--quiet",
      "refs/heads/#{name}", out: File::NULL, err: File::NULL)
  end
end

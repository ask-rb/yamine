# frozen_string_literal: true

require "open3"
require "pathname"

module Yamine
  # Variant resolution: the malleable axis of the hostname.
  #
  # Precedence: explicit --variant flag -> YAMINE_VARIANT env ->
  # linked git worktree branch -> current git branch (opt-in via
  # --branch / YAMINE_BRANCH=1) -> none.
  #
  # Main/master (and detached HEAD) never produce a variant.
  module Variant
    DEFAULT_BRANCHES = %w[main master].freeze

    module_function

    # Returns [variant, source] or nil.
    def resolve(cwd = Dir.pwd, explicit: nil, use_branch: false)
      return labeled(explicit, "flag") if present?(explicit)

      env = ENV["YAMINE_VARIANT"]
      return labeled(env, "YAMINE_VARIANT") if present?(env)

      worktree = worktree_prefix(cwd)
      return [worktree, "git worktree"] if worktree

      branch_flag = use_branch || %w[1 true].include?(ENV["YAMINE_BRANCH"])
      return nil unless branch_flag

      branch = current_branch(cwd)
      prefix = branch_to_prefix(branch)
      prefix ? [prefix, "git branch"] : nil
    end

    def apply(base_name, variant)
      variant ? "#{variant}.#{base_name}" : base_name
    end

    # NOTE: do not add a `private` keyword in this module — it would
    # cancel `module_function` mode and demote the helpers below to
    # plain private instance methods. They stay module functions
    # (private as instance methods) by omitting it.
    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    def labeled(value, source)
      label = Sanitize.hostname_label(value)
      label.empty? ? nil : [label, source]
    end

    # The whole branch, not just its last path segment. `feature/login`
    # and `bugfix/login` are different worktrees and must not end up
    # sharing a hostname; taking the last segment alone collapsed them
    # both to `login`.
    def branch_to_prefix(branch)
      return nil if branch.nil? || branch.empty?
      return nil if branch == "HEAD" || DEFAULT_BRANCHES.include?(branch)

      label = Sanitize.hostname_label(branch)
      label.empty? ? nil : label
    end

    # A detached HEAD has no branch to name it, so the worktree's
    # directory does — the same identity the per-worktree database is
    # keyed on. Without this, a detached worktree would fall back to the
    # bare app name and answer on the main checkout's hostname.
    def worktree_dir_prefix(cwd)
      top, status = git(cwd, "rev-parse", "--show-toplevel")
      return nil unless status.success?

      label = Sanitize.hostname_label(File.basename(top.strip))
      label.empty? ? nil : label
    end

    # Only linked worktrees (created via `git worktree add`) get a prefix.
    # Developers on feature branches in their main checkout keep the bare name.
    def worktree_prefix(cwd)
      list_out, list_status = git(cwd, "worktree", "list", "--porcelain")
      return nil unless list_status.success?

      count = list_out.lines.count { |l| l.start_with?("worktree ") }
      return nil if count <= 1

      git_dir, s1 = git(cwd, "rev-parse", "--git-dir")
      common_dir, s2 = git(cwd, "rev-parse", "--git-common-dir")
      return nil unless s1.success? && s2.success?

      # Same dir => main worktree, no prefix.
      expanded = File.expand_path(git_dir.strip, cwd)
      expanded_common = File.expand_path(common_dir.strip, cwd)
      return nil if expanded == expanded_common

      branch, s3 = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
      return nil unless s3.success?

      branch_to_prefix(branch.strip) || worktree_dir_prefix(cwd)
    rescue SystemCallError
      filesystem_worktree_prefix(cwd)
    end

    # Fallback when git CLI is unavailable: a linked worktree has a .git
    # FILE pointing into a /worktrees/ path (submodules point to /modules/).
    def filesystem_worktree_prefix(cwd)
      dir = Pathname.new(File.expand_path(cwd))
      until dir.root?
        git_path = dir.join(".git")
        if git_path.file?
          content = git_path.read.strip
          match = content.match(/\Agitdir:\s*(.+)\z/)
          if match && match[1].match?(%r{[/\\]worktrees[/\\][^/\\]+\z})
            head = File.join(File.expand_path(match[1], dir.to_s), "HEAD")
            branch = read_branch_from_head(head)
            # Same rule as the git path: branch when there is one, the
            # worktree directory otherwise (detached HEAD).
            prefix = branch_to_prefix(branch.to_s) || Sanitize.hostname_label(dir.basename.to_s)
            return prefix.empty? ? nil : prefix
          end
          return nil
        end
        return nil if git_path.directory?

        dir = dir.parent
      end
      nil
    rescue SystemCallError
      nil
    end

    def read_branch_from_head(head_path)
      content = File.read(head_path).strip
      match = content.match(%r{\Aref:\s*refs/heads/(.+)\z})
      match && match[1]
    rescue SystemCallError
      nil
    end

    def current_branch(cwd)
      out, status = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
      status.success? ? out.strip : nil
    end

    def git(cwd, *args)
      Open3.capture2("git", *args, chdir: cwd, err: File::NULL)
    rescue SystemCallError, ArgumentError
      ["", nil]
    end
  end
end

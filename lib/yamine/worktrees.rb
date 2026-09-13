# frozen_string_literal: true

require "open3"

module Yamine
  # Git worktree plumbing for `yamine worktree add|list|remove|clean`.
  #
  # Thin wrappers over the git CLI: failures carry git's own stderr so
  # the user sees git's reason, not a paraphrase. Every caller filters
  # out the main checkout (Entry#main?) — cleanup commands must never
  # be able to touch it, so the filter lives in the data, not in
  # whoever remembers to check.
  module Worktrees
    module_function

    Entry = Struct.new(:path, :head, :branch, :detached, :bare, keyword_init: true) do
      def main?
        Database.main_checkout?(path)
      end

      def exists?
        File.directory?(path)
      end
    end

    # All worktrees of the repo `dir` belongs to, main checkout first
    # (git always lists it first). Empty when `dir` is not a repo.
    def list(dir = Dir.pwd)
      out, status = git(dir, "worktree", "list", "--porcelain")
      return [] unless status&.success?

      parse(out)
    end

    def parse(porcelain)
      entries = []
      entry = nil
      porcelain.lines.each do |line|
        key, value = line.strip.split(" ", 2)
        case key
        when "worktree"
          entries << entry if entry
          entry = Entry.new(path: File.expand_path(value.to_s), head: nil,
            branch: nil, detached: false, bare: false)
        when "HEAD" then entry&.head = value
        when "branch" then entry&.branch = value.to_s.sub(%r{\Arefs/heads/}, "")
        when "detached" then entry&.detached = true
        when "bare" then entry&.bare = true
        end
      end
      entries << entry if entry
      entries
    end

    # The worktree whose branch or directory basename is `name`.
    def find(dir, name)
      list(dir).find do |entry|
        next false if entry.bare

        entry.branch == name || File.basename(entry.path) == name
      end
    end

    # Create a worktree on `branch`: checked out when the branch already
    # exists, created otherwise. Returns [stderr, status]; stderr is
    # user-facing on failure.
    def add(base_dir, branch, path)
      if branch_exists?(base_dir, branch)
        run(base_dir, "worktree", "add", path, branch)
      else
        run(base_dir, "worktree", "add", "-b", branch, path)
      end
    end

    def remove(base_dir, path, force: false)
      args = ["worktree", "remove"]
      args << "--force" if force
      run(base_dir, *args, path)
    end

    # Forget worktree admin entries whose directories are gone.
    def prune(base_dir)
      run(base_dir, "worktree", "prune")
    end

    def branch_exists?(base_dir, branch)
      _out, status = git(base_dir, "rev-parse", "--verify", "--quiet",
        "refs/heads/#{branch}")
      status&.success?
    end

    # Uncommitted changes at `path`, disregarding `ignore` paths. The
    # per-checkout config yamine copies (config/local.yml, local.secrets)
    # is supposed to be present and is usually gitignored anyway —
    # without the ignore list a freshly-added worktree reads as dirty
    # and no cleanup could ever take it down without --force.
    def dirty?(path, ignore: [])
      out, status = git(path, "status", "--porcelain")
      return false unless status&.success?

      # Porcelain is column-based: XY then a space, path at index 3 —
      # XY itself is often " M" or "??", so the path must be cut by
      # position, never by stripping whitespace first.
      out.lines.any? do |line|
        next false if line.strip.empty?

        !ignore.include?(line[3..].to_s.strip)
      end
    end

    # Is `branch` fully merged into `into`? Anything git cannot answer
    # is reported unmerged, so deletion stays the explicit choice.
    def merged?(base_dir, branch, into:)
      return false unless branch && into

      _out, status = git(base_dir, "merge-base", "--is-ancestor", branch, into)
      status&.success?
    end

    # The branch cleanup merges against: a local main or master when one
    # exists, else whatever origin/HEAD points at, else master.
    def default_branch(base_dir)
      Variant::DEFAULT_BRANCHES.each do |candidate|
        return candidate if branch_exists?(base_dir, candidate)
      end

      out, status = git(base_dir, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
      return out.strip.sub(%r{\Arefs/remotes/origin/}, "") if status&.success? && !out.strip.empty?

      "master"
    end

    # Capture stderr: for add/remove, git's message IS the error.
    def run(dir, *args)
      out, status = Open3.capture2e("git", *args, chdir: dir)
      [out, status]
    rescue SystemCallError, ArgumentError => e
      [e.message, nil]
    end

    def git(dir, *args)
      Open3.capture2("git", *args, chdir: dir, err: File::NULL)
    rescue SystemCallError, ArgumentError
      ["", nil]
    end
  end
end

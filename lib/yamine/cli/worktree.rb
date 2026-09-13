# frozen_string_literal: true

require "fileutils"
require "open3"

module Yamine
  class CLI
    # Worktree lifecycle. yamine already gives every linked worktree its
    # own URL, database, and routes; these commands let it own the whole
    # span, from `add` (create + make it bootable with no follow-up
    # work) to `clean` (when a branch is merged, take down everything
    # the worktree stood up, including the worktree itself).
    #
    # Safety rails, in order of hardness:
    #   * the main checkout is never a candidate (Worktrees filters it);
    #   * `clean` never touches a worktree with uncommitted changes;
    #   * branches are deleted with `git branch -d`, so git itself
    #     refuses to drop unmerged refs — `clean --all` may remove an
    #     unmerged worktree but never its branch;
    #   * only `worktree remove --force` (git --force + branch -D)
    #     overrides, and it names what it discarded;
    #   * a database drop that fails aborts the teardown before the
    #     directory is touched, keeping the claim for a retry.
    module WorktreeCommand
      module_function

      # Per-checkout config that git does not carry: a fresh worktree
      # boots without these (missing secrets, no proxy config) — the
      # single largest follow-up cost of a new worktree.
      LOCAL_CONFIG_FILES = %w[config/local.yml config/local.secrets].freeze

      def run(ctx, args)
        sub = args.first
        case sub
        when "list", nil then list(ctx, args[1..] || [])
        when "add" then add(ctx, args[1..] || [])
        when "remove" then remove(ctx, args[1..] || [])
        when "clean" then clean(ctx, args[1..] || [])
        else
          raise Error,
            "Usage: yamine worktree list | add <name> [--dir <path>] [--no-install] | " \
            "remove <name> [--force] | clean [--all] [--dry-run]"
        end
      end

      def list(ctx, _args)
        map = Database.load_map(ctx.store.dir)
        repo = repo_top
        printed = false

        if repo
          default_branch = Worktrees.default_branch(repo)
          Worktrees.list(repo).each do |entry|
            next if entry.bare
            puts "  #{entry_line(entry, claim_for(map, entry.path), repo, default_branch)}"
            printed = true
          end
        end
        map.select { |_, info| !File.directory?(info["dir"]) }.each do |name, info|
          puts "  #{name}  #{info["dir"]}  (gone)"
          printed = true
        end
        puts "No worktrees or database claims." unless printed
      end

      def entry_line(entry, claim, repo, default_branch)
        name = entry.main? ? "main" : (entry.branch || "(detached)")
        line = "#{name}  #{entry.path}"
        line += "  db #{claim[0]}" if claim

        flags = []
        flags << "main checkout" if entry.main?
        flags << "detached" if entry.detached && !entry.main?
        flags << "dir gone" unless entry.exists?
        if !entry.main? && entry.exists?
          flags << "dirty" if Worktrees.dirty?(entry.path, ignore: LOCAL_CONFIG_FILES)
          if entry.detached
            flags << "unmerged"
          else
            merged = Worktrees.merged?(repo, entry.branch, into: default_branch)
            flags << (merged ? "merged" : "unmerged")
          end
        end
        line += "  (#{flags.join(", ")})" unless flags.empty?
        line
      end

      # yamine worktree add <name> [--dir <path>] [--no-install]
      #
      # `name` is the branch (feature/login stays feature/login — the
      # whole branch is the hostname label). The worktree lands beside
      # the repo as <repo>-<label>, receives the gitignored per-checkout
      # config, a bundle install, and its own database with schema, so
      # the next step is just `yamine start` in it.
      def add(ctx, args)
        opts, rest = take_flags(args, value_flags: %w[--dir], flags: %w[--no-install])
        name = rest.first
        unless name
          raise Error, "Usage: yamine worktree add <name> [--dir <path>] [--no-install]"
        end

        repo = repo_top || abort_not_in_repo
        label = Sanitize.hostname_label(name)
        if label.empty?
          raise Error, "#{name.inspect} has no usable hostname label"
        end
        if Variant::DEFAULT_BRANCHES.include?(name)
          raise Error, "refusing to create a worktree on the default branch #{name.inspect}"
        end

        dir = opts[:dir] || File.expand_path("../#{File.basename(repo)}-#{label}", repo)
        if File.exist?(dir)
          raise Error, "#{dir} already exists — remove it first or pass --dir"
        end

        out, status = Worktrees.add(repo, name, dir)
        unless status&.success?
          $stderr.puts "Error: git worktree add failed:"
          $stderr.puts out.to_s.gsub(/^/, "  ")
          exit 1
        end
        puts "  created #{dir} (branch #{name})"

        copied = copy_local_config(repo, dir)
        copied.each { |f| puts "  copied #{f}" }
        if copied.empty?
          puts "  no config/local.yml in #{repo} — run `yamine init` in the worktree before booting"
        end

        install_deps(dir) unless opts[:no_install]

        db_name = prepare_database(ctx, dir)
        say_ready(ctx, dir, name, db_name)
      end

      def copy_local_config(from_dir, to_dir)
        copied = []
        LOCAL_CONFIG_FILES.each do |rel|
          src = File.join(from_dir, rel)
          next unless File.file?(src)

          dst = File.join(to_dir, rel)
          FileUtils.mkdir_p(File.dirname(dst))
          FileUtils.cp(src, dst)
          copied << rel
        end
        copied
      end

      # The deps phase would fail-fast on a missing bundle anyway; doing
      # it here turns "add" into "ready to boot". Failure warns and
      # continues — boot's own pre-flight reports it with the fix.
      def install_deps(dir)
        return unless File.file?(File.join(dir, "Gemfile"))

        puts "  bundle install..."
        system("bundle", "install", chdir: dir)
        puts "  bundle install did not finish — run it in #{dir} before booting" unless $?.success?
      end

      # Claim the per-worktree database and create it now (with the
      # app's schema) so server problems surface at creation time, not
      # at first boot. Boot reuses an existing database idempotently, so
      # this is never wasted work. SQLite and template-less apps need
      # nothing; setup_database says so itself.
      def prepare_database(ctx, dir)
        return nil unless Config.load(dir)

        db_name = Database.name_for(dir, env: BootCommand.rails_env,
          state_dir: ctx.store.dir)
        Dir.chdir(dir) do
          BootCommand.setup_database(ctx, Resolver.resolve(dir), db_name)
        end
        db_name
      end

      def say_ready(ctx, dir, name, db_name)
        puts "Worktree ready:"
        puts "  dir      #{dir}"
        puts "  branch   #{name}"
        puts "  db       #{db_name}" if db_name
        if (resolved = resolved_quietly(dir))
          Resolver.urls(resolved, port: ctx.proxy_port, tls: ctx.proxy_tls)
            .each { |u| puts "  url      #{u}" }
        end
        puts "  boot it: cd #{dir} && yamine start"
      end

      def resolved_quietly(dir)
        Resolver.resolve(dir)
      rescue StandardError
        nil
      end

      # yamine worktree remove <name> [--force]
      #
      # Full teardown of one worktree, merge state regardless (the flag
      # only decides whether git may discard uncommitted changes and
      # delete an unmerged branch). --force is the only path that can
      # do either.
      def remove(ctx, args)
        opts, rest = take_flags(args, value_flags: [], flags: %w[--force])
        name = rest.first
        raise Error, "Usage: yamine worktree remove <name> [--force]" unless name

        repo = repo_top || abort_not_in_repo
        entry = Worktrees.find(repo, name)
        if entry.nil? || entry.main?
          raise Error, "no worktree named #{name.inspect} here — `yamine worktree list` shows what exists"
        end

        unless entry.exists?
          abandon(ctx, repo, entry)
          return
        end

        if Worktrees.dirty?(entry.path, ignore: LOCAL_CONFIG_FILES) && !opts[:force]
          $stderr.puts "Error: #{entry.path} has uncommitted changes."
          $stderr.puts "  Commit or stash them, or re-run with --force to discard them."
          exit 1
        end

        exit 1 unless teardown(ctx, repo, entry, force: opts[:force])
        Worktrees.prune(repo)
        resync_hosts(ctx)
      end

      # yamine worktree clean [--all] [--dry-run]
      #
      # The done-and-merged sweep: databases of worktree directories
      # that no longer exist (any repo), plus full teardown of this
      # repo's merged worktrees. Unmerged and dirty worktrees are kept,
      # with the reason — they are work in progress, not leftovers.
      def clean(ctx, args)
        opts, rest = take_flags(args, value_flags: [], flags: %w[--all --dry-run])
        unless rest.empty?
          raise Error, "Usage: yamine worktree clean [--all] [--dry-run]"
        end

        repo = repo_top
        plan = build_plan(ctx, repo, all: opts[:all])
        if plan.empty?
          puts "Nothing to clean."
          return
        end

        if opts[:dry_run]
          plan.each { |step| puts "  would #{step.describe}" }
          return
        end

        failures = 0
        changed = false
        plan.each do |step|
          case step[0]
          when :drop_db
            if drop_orphan(ctx, step[1], step[2])
              changed = true
            else
              failures += 1
            end
          when :teardown
            if teardown(ctx, repo, step[1], force: false)
              changed = true
            else
              failures += 1
            end
          when :prune
            changed = true
          when :keep
            puts "  kept #{step[1]} — #{step[2]}"
          end
        end
        Worktrees.prune(repo) if repo
        resync_hosts(ctx) if repo && changed
        ran = plan.count { |s| %i[drop_db teardown prune].include?(s[0]) }
        summary = "Cleaned #{ran} item(s)"
        summary += ", #{failures} failed" if failures.positive?
        puts "#{summary}."
        exit 1 if failures.positive?
      end

      Plan = Struct.new(:action, :subject, :reason) do
        def describe
          case action
          when :drop_db then "drop database #{subject} (#{reason} is gone)"
          when :teardown then "remove worktree #{subject.path} (#{reason})"
          when :prune then "prune stale git entry #{subject}"
          when :keep then "keep #{subject} — #{reason}"
          end
        end
      end

      def build_plan(ctx, repo, all:)
        plan = []
        Database.orphaned(ctx.store.dir).each do |name, info|
          plan << Plan.new(:drop_db, name, info["dir"])
        end
        return plan unless repo

        default_branch = Worktrees.default_branch(repo)
        Worktrees.list(repo).each do |entry|
          next if entry.bare || entry.main?

          unless entry.exists?
            plan << Plan.new(:prune, entry.path)
            next
          end
          if Worktrees.dirty?(entry.path, ignore: LOCAL_CONFIG_FILES)
            plan << Plan.new(:keep, entry.path, "uncommitted changes are never cleaned automatically")
            next
          end
          merged = Worktrees.merged?(repo, entry.branch, into: default_branch)
          if merged
            plan << Plan.new(:teardown, entry, "branch merged into #{default_branch}")
          elsif all
            plan << Plan.new(:teardown, entry,
              "--all; branch #{entry.branch} stays (unmerged into #{default_branch})")
          else
            plan << Plan.new(:keep, entry.path,
              "branch not merged into #{default_branch} (--all to override)")
          end
        end
        plan
      end

      # An admin entry whose directory vanished (rm -rf, a crashed
      # agent): drop the database it claimed, forget the claim. The git
      # entry itself is cleared by the trailing prune. A template with
      # no server behind it (sqlite) means there is nothing to drop and
      # no retry that could help — the claim is simply forgotten.
      def drop_orphan(ctx, name, _dir)
        template = orphan_template(ctx)
        unless template
          $stderr.puts "Error: no DATABASE_URL template found (ENV or env.clear in " \
            "config/local.yml) — cannot drop #{name}."
          return false
        end
        unless %i[postgres mysql].include?(Database.adapter_for(template))
          puts "  #{name} has no server database (sqlite/unknown adapter) — claim forgotten"
          forget_claim(ctx, name)
          return true
        end
        case Database.drop(name, template)
        when :dropped then puts "  dropped #{name}"
        when :missing then puts "  #{name} did not exist — nothing to drop"
        when :failed
          warn "  could not drop #{name} — is the server running? Claim kept for a retry."
          return false
        end
        forget_claim(ctx, name)
        true
      end

      def forget_claim(ctx, name)
        map = Database.load_map(ctx.store.dir)
        map.delete(name)
        Database.save_map(ctx.store.dir, map)
      end

      # Orphan directories are gone, so their configs are unreadable —
      # the template comes from the environment or whatever checkout the
      # command runs in, exactly as `db drop` has always done.
      def orphan_template(ctx)
        env = ENV["DATABASE_URL"]
        return env if env && !env.strip.empty?

        config = Config.load(Dir.pwd)
        config && Database.template_for(config)
      end

      # A worktree whose directory is already gone: nothing to stop or
      # remove, just its database claim and the stale git entry.
      def abandon(ctx, repo, entry)
        map = Database.load_map(ctx.store.dir)
        claim = claim_for(map, entry.path)
        if claim
          exit 1 unless drop_orphan(ctx, claim[0], entry.path)
        end
        Worktrees.prune(repo)
        puts "  pruned #{entry.path} (directory was already gone)"
      end

      # The teardown shared by `remove` and `clean`. Returns true when
      # the worktree is gone; false means abort with state intact for a
      # retry. The database drop happens BEFORE git removes the
      # directory: a failed drop must not leave a database behind with
      # no config to reach it.
      def teardown(ctx, repo, entry, force:)
        dir = entry.path
        map = Database.load_map(ctx.store.dir)
        claim = claim_for(map, dir)

        stop_routes(ctx, dir)

        if claim
          outcome = drop_database(repo, dir, claim[0])
          if outcome == :failed
            warn "  kept #{dir} — database drop failed; fix the server and re-run"
            return false
          end
          map = Database.load_map(ctx.store.dir)
          map.delete(claim[0])
          Database.save_map(ctx.store.dir, map)
        end

        out, status = Worktrees.remove(repo, dir, force: force)
        unless status&.success?
          $stderr.puts "Error: git worktree remove failed:"
          $stderr.puts out.to_s.gsub(/^/, "  ")
          return false
        end
        puts "  removed #{dir}"

        if entry.branch
          flag = force ? "-D" : "-d"
          _o, deleted = Open3.capture2("git", "branch", flag, entry.branch, chdir: repo,
            err: File::NULL)
          if deleted&.success?
            puts "  deleted branch #{entry.branch}"
          else
            puts "  kept branch #{entry.branch} (git refuses to delete an unmerged branch)"
          end
        end
        true
      end

      # Routes registered from this worktree (spec.dir marks
      # boot-registered backends). The directory is about to disappear,
      # so live backends are stopped regardless of which agent owns
      # them — no route could survive the removal anyway, and leaving a
      # live process with its working directory deleted is worse.
      def stop_routes(ctx, dir)
        routes = ctx.store.load_routes_raw.select do |r|
          r.dig("spec", "dir") == File.expand_path(dir)
        end
        routes.each do |entry|
          hostname = entry["hostname"]
          backend_pid = ctx.backend_pid_for(entry)
          if backend_pid && ProxyControl.pid_alive?(backend_pid)
            begin
              Process.kill("TERM", backend_pid)
              ctx.wait_for_exit(backend_pid, timeout: 10)
            rescue SystemCallError
              nil
            end
          end
          ctx.store.remove_route(hostname)
          FileUtils.rm_f(File.join(ctx.store.dir, "backend-#{hostname}.pid"))
          puts "  stopped #{hostname}"
        end
      end

      def drop_database(repo, dir, name)
        template = drop_template_for(repo, dir)
        adapter = template && Database.adapter_for(template)
        unless %i[postgres mysql].include?(adapter)
          puts "  no server database to drop for #{name} " \
            "(#{template ? "sqlite/unknown adapter" : "no DATABASE_URL template"})"
          return :missing
        end

        outcome = Database.drop(name, template)
        case outcome
        when :dropped then puts "  dropped #{name}"
        when :missing then puts "  #{name} did not exist — nothing to drop"
        when :failed then puts "  could not drop #{name} — is the database server running?"
        end
        outcome
      end

      # Reach the database server from the worktree's own config (read
      # BEFORE the directory is removed), falling back to the main
      # checkout, then the environment.
      def drop_template_for(repo, dir)
        [dir, repo].each do |base|
          config = Config.load(base) rescue nil
          next unless config

          template = Database.template_for(config)
          return template if template && !template.strip.empty?
        end
        ENV["DATABASE_URL"]
      end

      # The removed routes should leave the hosts block too. Best-effort:
      # the file is root-owned, and the next boot's workstation check
      # re-syncs anyway.
      def resync_hosts(ctx)
        ctx.store.prune_stale
        hostnames = ctx.store.load_routes.map { |r| r["hostname"] }
        return if Hosts.sync(hostnames)

        warn "Warning: could not update /etc/hosts (try sudo yamine hosts sync)."
      end

      def claim_for(map, dir)
        expanded = File.expand_path(dir)
        map.find { |_, info| info["dir"] == expanded }
      end

      def repo_top
        out, status = Open3.capture2("git", "rev-parse", "--show-toplevel",
          chdir: Dir.pwd, err: File::NULL)
        status&.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      def abort_not_in_repo
        $stderr.puts "Error: not inside a git repository — run from the app's checkout."
        exit 1
      end

      def take_flags(args, value_flags:, flags:)
        opts = {}
        rest = []
        until args.empty?
          arg = args.shift
          next rest << arg unless arg.start_with?("--")

          if value_flags.include?(arg)
            opts[arg.sub(/\A--/, "").tr("-", "_").to_sym] = args.shift
          elsif flags.include?(arg)
            opts[arg.sub(/\A--/, "").tr("-", "_").to_sym] = true
          else
            raise Error, "Unknown flag #{arg}"
          end
        end
        [opts, rest]
      end
    end
  end
end

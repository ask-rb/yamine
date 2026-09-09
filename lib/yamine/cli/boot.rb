# frozen_string_literal: true

module Yamine
  class CLI
    # Boot commands: `yamine`, `yamine start`, `yamine run`.
    # The config file is mandatory — missing file prints the fix and exits.
    # `boot_all` fans out over every process declared in config/local.yml.
    # No inference, no Procfile at boot, no single-process default.
    module BootCommand
      PORT_IGNORING = %w[jekyll middleman bridgetown].freeze

      module_function

      # Bare `yamine` / `yamine start` / `yamine run`.
      # Reads config/local.yml via the resolver, ensures the proxy,
      # boots every process, supervises the tree, cleans up on exit.
      def run_inferred(ctx, args)
        variant = ENV["YAMINE_VARIANT"]
        opts = ctx.parse_flags(args, %i[variant tld force])
        resolved = resolve!(ctx, variant: opts[:variant] || variant, tld: opts[:tld])
        # Ownership gate before any side effects: no proxy spawn, no
        # port allocation when we'd refuse anyway.
        check_worktree_ownership!(ctx, resolved, force: opts[:force])
        ensure_proxy!(ctx)
        boot_all(ctx, resolved, opts)
      end

      def run_explicit(ctx, args)
        run_inferred(ctx, args)
      end

      def run_named(ctx, name, _args)
        $stderr.puts "Error: `yamine #{name}` is no longer supported."
        $stderr.puts "  All processes come from config/local.yml. Run `yamine init` to create one."
        exit 1
      end

      # Core boot loop: iterate processes from config/local.yml,
      # classify HTTP vs background, spawn each, register routes for
      # HTTP processes, then supervise the tree.
      def boot_all(ctx, resolved, opts)
        service = resolved.app
        tld = resolved.tld
        host = resolved.host
        processes = resolved.processes

        if processes.empty?
          $stderr.puts "Error: no processes in config/local.yml. Add at least one."
          exit 1
        end

        primary = Resolver.primary_proc(resolved)
        if primary.nil?
          $stderr.puts "Error: no HTTP process (proxy: true) found in config/local.yml."
          exit 1
        end

        runner = Runner.new(store: ctx.store)
        children = []
        routes_registered = []

        puts "yamine (#{service})"
        puts "--"

        # Per-worktree database: one database per directory so concurrent
        # agents never share tables. Resolved once, injected into every
        # process as DATABASE_URL, created on demand with the app's own
        # schema-load command. SQLite needs nothing (relative paths
        # already isolate); the branch plays no part (dirs are stable,
        # branches hop).
        db_name = Database.name_for(Dir.pwd, env: rails_env,
          state_dir: ctx.store.dir)
        db_url = setup_database(ctx, resolved, db_name)
        puts "  [db] #{db_name}" if db_url

        processes.each do |proc_name, entry|
          hostname = Resolver.hostname_for(resolved, proc_name)
          if entry["proxy"] == false
            boot_background(ctx, runner, resolved, proc_name, entry, opts, children, db_url)
            next
          end
          next unless hostname

          url = Hostname.url(hostname, port: ctx.proxy_port, tls: ctx.proxy_tls)
          hostnames = [hostname]
          puts "  [#{proc_name}] #{url}"

          # Each process cmd runs through the shell so $PORT (and other
          # env refs) expand — same trust boundary as a Procfile line
          # (repo code, not user input). Compound lines are refused.
          cmd = entry["cmd"].to_s
          if cmd.match?(Yamine::Procfile::COMPOUND)
            $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — run explicitly: yamine run -- #{cmd}"
            next
          end

          port = opts[:app_port] || Ports.find_free
          shell_cmd = ["sh", "-c", cmd]
          # Always allow the proxied hostname in Rails dev (Rails ignores
          # this env var when not a Rails app — safe for every framework).
          # DATABASE_URL points at this worktree's own database; non-Ruby
          # frameworks that honor it get isolation for free, others ignore it.
          app = runner.boot_run(name: proc_name, hostname: hostname, url: url,
            dir: Dir.pwd, command: shell_cmd, port: port, force: opts[:force],
            rails_dev_host: hostname, database_url: db_url)
          register_all(ctx, hostnames, app, force: opts[:force],
            spec: { "dir" => File.expand_path(Dir.pwd), "proc" => proc_name })
          routes_registered << { hostnames: hostnames, app: app }

          puts "  -> #{url}"
        end

        background = processes.select { |_, v| v["proxy"] == false }
        unless background.empty?
          puts "  [background] #{background.keys.join(', ')}"
        end

        puts
        ctx.report_unresolved(routes_registered.flat_map { |r| r[:hostnames] })

        # Supervisor: exit when ANY child dies (loud cleanup).
        all_pids = routes_registered.map { |r| r[:app].pid } + children.map { |c| c[:pid] }
        all_hostnames = routes_registered.flat_map { |r| r[:hostnames] }
        trap_cleanup(ctx, all_hostnames, all_pids)
        supervise_tree(ctx, all_hostnames, all_pids)
      end

      # A background process (proxy: false) is spawned, logged, and
      # supervised exactly like an HTTP one — it just gets no route.
      def boot_background(ctx, runner, resolved, proc_name, entry, opts, children, db_url)
        cmd = entry["cmd"].to_s
        if cmd.match?(Yamine::Procfile::COMPOUND)
          $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — run explicitly: yamine run -- #{cmd}"
          return
        end
        port = opts[:app_port] || Ports.find_free
        url = "background://#{resolved.app}/#{proc_name}"
        app = runner.boot_run(name: proc_name, hostname: "#{resolved.app}.#{proc_name}.internal",
          url: url, dir: Dir.pwd, command: ["sh", "-c", cmd], port: port,
          force: opts[:force], rails_dev_host: nil, register: false,
          database_url: db_url)
        children << { name: proc_name, pid: app.pid }
        puts "  [#{proc_name}] background (pid #{app.pid})"
      end

      # Refuse to boot over another agent's live routes unless forced.
      # Compares our worktree dir (spec.dir) against the owner's: same
      # dir + same agent is a restart, anything else names the owner.
      def check_worktree_ownership!(ctx, resolved, force:)
        mine = Agent.name
        here = File.expand_path(Dir.pwd)
        Resolver.hostnames(resolved).each do |hostname|
          entry = ctx.store.find(hostname)
          next unless entry
          next unless entry["pid"] != 0 && ProxyControl.pid_alive?(entry["pid"])
          next if entry["agent"] == mine && entry.dig("spec", "dir") == here
          next if force

          owner = entry["agent"] && !entry["agent"].empty? ? "agent #{entry["agent"].inspect}" : "PID #{entry["pid"]}"
          dir = entry.dig("spec", "dir")
          $stderr.puts "Error: #{hostname} is live and owned by #{owner}#{dir ? " (#{dir})" : ""}."
          $stderr.puts "  Work in your own worktree (each branch gets its own URL), or take over explicitly:"
          $stderr.puts "    yamine start --force"
          exit 1
        end
      end

      def build_env(ctx, resolved, entry)
        env = {}
        # Merge config env.clear
        config_env = resolved.secrets || {}
        entry_env = entry["env"] || {}
        (entry_env["clear"] || {}).each { |k, v| env[k] = v }
        # Merge secrets from config/local.secrets
        secret_keys = entry_env["secret"] || []
        secret_keys.each do |k|
          env[k] = config_env[k] if config_env.key?(k)
        end
        # Host env (dotenv from .env) already in ENV
        env
      end

      # Rails env for database naming: RAILS_ENV when set, else development.
      # Non-Rails apps ignore it (their DATABASE_URL template decides).
      def rails_env
        ENV.fetch("RAILS_ENV", "development")
      end

      # Resolve this worktree's database, create it if missing, and run
      # the app's schema-load command on first creation. Returns the
      # DATABASE_URL for injection, or nil when there's nothing to do
      # (no template URL, sqlite, or the app opted out via db: false).
      def setup_database(ctx, resolved, db_name)
        return nil if resolved.processes["db"] == false

        template = ENV["DATABASE_URL"] || database_template_from_config(resolved)
        return nil if template.nil? || template.strip.empty?

        url = Database.url_for(db_name, template)
        return nil unless url

        if Database.ensure_exists(db_name, template)
          puts "  [db] created #{db_name}" unless database_exists?(db_name, template)
          run_schema_load(resolved, url)
        else
          $stderr.puts "  [db] WARNING: could not create #{db_name} — processes share the template database."
          return nil
        end
        url
      end

      def database_exists?(name, template)
        # ensure_exists is idempotent; this second call is cheap (psql -lqt)
        # and tells us whether to print "created" vs nothing.
        Database.ensure_exists(name, template)
      end

      def database_template_from_config(resolved)
        env = resolved.processes.values.map { |e| e["env"] || {} }
        clear = env.map { |e| e["clear"] || {} }.reduce({}, :merge)
        clear["DATABASE_URL"]
      end

      # Schema-load on first boot uses the app's own command when declared
      # (db.schema_load in config/local.yml), else a Rails default when a
      # Rails app is detected, else nothing (frameworks without a
      # schema concept need no step).
      def run_schema_load(resolved, url)
        cmd = resolved.processes.dig("db", "schema_load") ||
          ("bin/rails db:schema:load" if rails_app?)
        return unless cmd

        system({ "DATABASE_URL" => url, "RAILS_ENV" => rails_env },
          "sh", "-c", cmd, chdir: Dir.pwd, out: File::NULL, err: File::NULL)
      end

      def rails_app?
        File.file?(File.join(Dir.pwd, "config", "application.rb"))
      end

      def supervise_tree(ctx, hostnames, pids)
        loop do
          sleep 0.5
          if pids.any? { |pid| !ProxyControl.pid_alive?(pid) }
            puts "\nA process exited — cleaning up all routes."
            cleanup_routes(ctx, hostnames)
            # Kill remaining children
            pids.each do |pid|
              Process.kill("TERM", pid) rescue nil
            end
            exit 0
          end
        end
      end

      def inject_port_flags(command, port)
        return command if command.empty?
        return command if command.any? { |a| a.match?(/\A(-p|--port)(=|\z)/) }
        return command if command.any? { |a| a.include?("$PORT") }

        bin = File.basename(command.first.to_s)
        needs_flags = PORT_IGNORING.include?(bin) ||
          (command.length > 2 && PORT_IGNORING.include?(File.basename(command[2].to_s)))
        return command unless needs_flags

        command + ["--port", port.to_s, "--host", "127.0.0.1"]
      end

      # Legacy procfile parsing for backwards compat.
      def procfile_command(process = nil)
        path = ::Yamine::Procfile.find_file(Dir.pwd)
        return nil unless path
        lines = ::Yamine::Procfile.parse_file(path)
        line = if process
                 lines.find { |l| l.name == process }
               else
                 lines.first
               end
        return nil unless line
        line.compound ? nil : ["sh", "-c", line.command]
      end

      def trap_cleanup(ctx, hostnames, pids = [])
        %w[INT TERM].each do |sig|
          trap(sig) do
            cleanup_routes(ctx, hostnames)
            pids.each { |pid| Process.kill("TERM", pid) rescue nil }
            exit 0
          end
        end
      end

      def register_all(ctx, hostnames, app, force:, spec: nil)
        hostnames[1..].each do |h|
          ctx.store.add_route(h, app.target, Process.pid, kind: app.kind,
            force: force, spec: spec)
          write_backend_sidecar(ctx, h, app.pid)
        end
      end

      def write_backend_sidecar(ctx, hostname, pid)
        ctx.store.ensure_dir
        File.write(File.join(ctx.store.dir, "backend-#{hostname}.pid"), "#{pid}\n")
      rescue SystemCallError
        nil
      end

      def cleanup_routes(ctx, hostnames)
        hostnames.each do |h|
          begin
            entry = ctx.store.find(h)
            pid = ctx.backend_pid_for(entry) if entry
            if pid && ProxyControl.pid_alive?(pid)
              Process.kill("TERM", pid) rescue nil
            end
            ctx.store.remove_route(h, owner_pid: Process.pid) rescue nil
            FileUtils.rm_f(File.join(ctx.store.dir, "backend-#{h}.pid"))
          rescue StandardError
            nil
          end
        end
      end

      def resolve!(ctx, variant: nil, tld: nil)
        # The resolver calls Config.load, which raises ConfigError if
        # config/local.yml is missing — exactly what we want.
        Yamine::Resolver.resolve(Dir.pwd, variant: variant, tld: tld)
      end

      def ensure_proxy!(ctx)
        port = ctx.proxy_port
        tls = ctx.proxy_tls
        if ProxyControl.listening?(port)
          return if ProxyControl.ours?(port, tls: tls)
          $stderr.puts "Error: port #{port} is in use by another process."
          $stderr.puts "  Stop it, or yamine proxy start -p <port>"
          exit 1
        end
        privileged = port < 1024 && !ProxyControl.root?
        if privileged && !ctx.interactive?
          $stderr.puts "Error: proxy is not running and port #{port} needs root."
          $stderr.puts "  Human: run this once — yamine setup"
          $stderr.puts "  Agent/CI: pre-provision passwordless sudo once —"
          $stderr.puts "    yamine sudoers > /tmp/yamine.sudoers"
          $stderr.puts "    sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine"
          $stderr.puts "  Or start the proxy by hand: sudo yamine proxy start"
          exit 1
        end
        puts "Starting proxy#{privileged ? " (sudo)" : ""}..."
        begin
          Yamine::ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, sudo: privileged)
        rescue Yamine::ProxyNotRunningError => e
          $stderr.puts "Error: #{e.message.lines.first&.strip}"
          $stderr.puts "  Fix once: yamine setup"
          exit 1
        end
      rescue Errno::EACCES
        $stderr.puts "Error: permission denied binding port #{port}."
        $stderr.puts "  Fix once: yamine setup"
        exit 1
      end
    end
  end
end

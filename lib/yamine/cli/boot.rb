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
        opts = ctx.parse_flags(args, %i[variant tld force app_port wait no_wait json branch])
        resolved = resolve!(ctx, variant: opts[:variant] || variant, tld: opts[:tld],
          use_branch: opts[:branch])
        # Ownership gate before any side effects: no proxy spawn, no
        # port allocation when we'd refuse anyway.
        check_worktree_ownership!(ctx, resolved, force: opts[:force])
        ensure_proxy!(ctx, json: opts[:json])
        boot_all(ctx, resolved, opts)
      end

      # Progress sink for the boot's phases. Human runs narrate to stderr
      # (stdout is the payload); --json runs emit one JSON line per event
      # on stdout. Without this the phase events were computed and thrown
      # away (opts[:events] was never set), so a 2-minute dependency or
      # healthcheck phase looked like a hang.
      def reporter(json:)
        json ? Log::Report::Json.new : Log::Report::Human.new
      end

      # Boot banner / URL lines. In --json mode they move to stderr so
      # stdout stays pure JSON (one event per line, payload last) for
      # agents that parse it; humans still get them on stdout.
      def say(opts, message = "")
        opts[:json] ? $stderr.puts(message) : puts(message)
      end

      def run_explicit(ctx, args)
        run_inferred(ctx, args)
      end

      def run_named(ctx, name, _args)
        if name.to_s.start_with?("-")
          $stderr.puts "Error: unknown flag `#{name}`. Try `yamine --help` or `yamine start --help`."
        else
          $stderr.puts "Error: `yamine #{name}` is no longer supported."
          $stderr.puts "  All processes come from config/local.yml. Run `yamine init` to create one."
        end
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
        events = opts[:events] || reporter(json: opts[:json])

        if processes.empty?
          $stderr.puts "Error: no processes in config/local.yml. Add at least one."
          exit 1
        end

        primary = Resolver.primary_proc(resolved)
        if primary.nil?
          $stderr.puts "Error: no HTTP process (proxy: true) found in config/local.yml."
          exit 1
        end

        # Pre-flight: verify runtime deps BEFORE spawning anything.
        # A missing bundle fails here in seconds with the fix, instead
        # of a 60s Puma crash-loop ending in "did not boot".
        deps = Readiness.phase(:deps, "deps", sink: events) do
          ok, fix = Readiness.check_deps(Dir.pwd)
          raise fix unless ok

          "dependencies satisfied"
        end
        unless deps.status == "ok"
          $stderr.puts "Error: #{deps.detail}"
          exit 1
        end

        # Pre-flight: a live tmp/pids/server.pid makes Rails refuse to
        # boot ("A server is already running") the moment web starts.
        # When the holder is this app's own puma (`puma ... [app]`), take
        # over automatically — that is one of ours. Anything else is not
        # ours to kill: fail with the exact fix before spawning.
        conflict_ok, conflict_detail, conflict_pid = Readiness.server_pid_conflict(Dir.pwd)
        unless conflict_ok
          if own_orphan_puma?(conflict_pid, resolved.app, Dir.pwd)
            say opts, "  reaping own orphaned server (pid #{conflict_pid})"
            reap_stale_server(conflict_pid)
          elsif opts[:force]
            say opts, "  --force: taking over pid #{conflict_pid}"
            reap_stale_server(conflict_pid)
          else
            $stderr.puts "Error: #{conflict_detail}."
            $stderr.puts "  Rails will refuse to boot while it runs. Free it first:"
            $stderr.puts "    kill #{conflict_pid} && rm tmp/pids/server.pid"
            $stderr.puts "  Or re-run with --force to let yamine take over that pid."
            exit 1
          end
        end

        runner = Runner.new(store: ctx.store)
        children = []
        routes_registered = []

        say opts, "yamine (#{service})"
        say opts, "--"

        # Per-worktree database: one database per directory so concurrent
        # agents never share tables. Resolved once, injected into every
        # process as DATABASE_URL, created on demand with the app's own
        # schema-load command. SQLite needs nothing (relative paths
        # already isolate); the branch plays no part (dirs are stable,
        # branches hop).
        db_name = Database.name_for(Dir.pwd, env: rails_env,
          state_dir: ctx.store.dir)
        db_created, db_url = setup_database(ctx, resolved, db_name, events: events)
        events&.note("[db] #{db_name}#{db_created ? " (created)" : ""}") if db_url

        with_wait = !opts[:no_wait]
        spawn_plan = collect_spawns(ctx, runner, resolved, opts, db_url, children)

        begin
          if with_wait
            boot_concurrent(ctx, runner, resolved, opts, spawn_plan, children,
              routes_registered, db_url, db_name, db_created, events: events)
          else
            boot_sequential(ctx, runner, resolved, opts, spawn_plan, children,
              routes_registered, db_url, events: events)
          end
        rescue StandardError
          # A raise mid-boot (route conflict, quota, unexpected error)
          # must never leave half a tree running: reap every child and
          # every route already registered, then surface the error.
          children.each { |c| stop_spawned_pid(c[:pid]) }
          cleanup_routes(ctx, routes_registered.flat_map { |r| r[:hostnames] })
          raise
        end

        background = processes.select { |_, v| v["proxy"] == false }
        unless background.empty?
          say opts, "  [background] #{background.keys.join(', ')}"
        end

        say opts
        ctx.report_unresolved(routes_registered.flat_map { |r| r[:hostnames] })

        # Supervisor: exit when ANY child dies (loud cleanup). pid => name
        # so the message names the casualty instead of "a process".
        named_pids = {}
        routes_registered.each { |r| named_pids[r[:app].pid] = r[:app].name }
        children.each { |c| named_pids[c[:pid]] = c[:name] }
        all_hostnames = routes_registered.flat_map { |r| r[:hostnames] }
        trap_cleanup(ctx, all_hostnames, named_pids.keys)
        supervise_tree(ctx, all_hostnames, named_pids, reporter: events)
      end

      # TERM the old server and make sure the pidfile no longer names
      # a live process before we spawn (wait a moment; then remove the
      # file if the process is still refusing to die, so Rails can boot
      # over it — the socket it held is already ours to take).
      def reap_stale_server(pid)
        Process.kill("TERM", pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          break unless ProxyControl.pid_alive?(pid)
          sleep 0.2
        end
        FileUtils.rm_f(File.join(Dir.pwd, "tmp", "pids", "server.pid"))
      rescue SystemCallError
        FileUtils.rm_f(File.join(Dir.pwd, "tmp", "pids", "server.pid"))
      end

      # Is this pid a leftover backend of THIS app? `puma (tcp://...)
      # [app]` names the app; we also accept a command containing the
      # app dir. Only then may we reap it unasked.
      def own_orphan_puma?(pid, app, dir)
        _out, status = Open3.capture2("ps", "-p", pid.to_s, "-o", "command=")
        return false unless status.success?

        cmd = _out.to_s
        cmd.include?("[#{app}]") || cmd.include?(File.expand_path(dir))
      rescue SystemCallError
        false
      end

      # One pass over config: background processes spawn immediately
      # (no route to wait on), HTTP processes become a spawn plan the
      # boot mode executes. Compound-line refusal happens here so both
      # paths share one rule.
      def collect_spawns(ctx, runner, resolved, opts, db_url, children)
        plan = []
        processes = resolved.processes
        processes.each do |proc_name, entry|
          hostname = Resolver.hostname_for(resolved, proc_name)
          if entry["proxy"] == false
            boot_background(ctx, runner, resolved, proc_name, entry, opts,
              children, db_url)
            next
          end
          next unless hostname

          url = Hostname.url(hostname, port: ctx.proxy_port, tls: ctx.proxy_tls)
          cmd = entry["cmd"].to_s
          if cmd.match?(Yamine::Procfile::COMPOUND)
            $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — run explicitly: yamine run -- #{cmd}"
            next
          end
          port = opts[:app_port] || Ports.find_free
          plan << { name: proc_name, entry: entry, hostname: hostname,
            hostnames: [hostname], url: url, port: port,
            command: ["sh", "-c", cmd] }
        end
        plan
      end

      # Default: sequential boot, route registered per process as before.
      def boot_sequential(ctx, runner, resolved, opts, plan, children,
        routes_registered, db_url, events: nil)
        plan.each do |item|
          say opts, "  [#{item[:name]}] #{item[:url]}"
          # Always allow the proxied hostname in Rails dev (Rails ignores
          # this env var when not a Rails app — safe for every framework).
          # DATABASE_URL points at this worktree's own database; non-Ruby
          # frameworks that honor it get isolation for free, others ignore it.
          # boot_run registers the route + backend sidecar itself
          # (register: true default); no separate adopt step needed.
          app = runner.boot_run(name: item[:name], hostname: item[:hostname],
            url: item[:url], dir: Dir.pwd, command: item[:command],
            port: item[:port], force: opts[:force],
            rails_dev_host: item[:hostname], database_url: db_url,
            extra_env: build_env(resolved, item[:entry], proc_name: item[:name]))
          routes_registered << { hostnames: item[:hostnames], app: app }

          say opts, "  -> #{item[:url]}"
        end
        children
      end

      # --wait: spawn everything first, then poll every port/path until
      # healthy. No route exists until its backend answers, so half-boots
      # never leak into the proxy. A backend that dies before its route
      # registers is cleaned up like any other failed process.
      def boot_concurrent(ctx, runner, resolved, opts, plan, children,
        routes_registered, db_url, db_name, db_created, events: nil)
        apps = {}
        plan.each do |item|
          say opts, "  [#{item[:name]}] #{item[:url]}"
          app = runner.spawn_http(name: item[:name], hostname: item[:hostname],
            url: item[:url], dir: Dir.pwd, command: item[:command],
            port: item[:port], rails_dev_host: item[:hostname],
            database_url: db_url, force: opts[:force],
            extra_env: build_env(resolved, item[:entry], proc_name: item[:name]))
          # Tracked before registration so any later failure (a raise
          # during adopt, a crash while another process waits) can
          # always reap it. Duplicate names in named_pids are harmless.
          children << { name: item[:name], pid: app.pid }
          apps[item[:name]] = {
            item: item,
            log_path: File.join(Dir.pwd, "log", "yamine-#{item[:name]}.log"),
            app: app
          }
        end
        wait_result = Readiness.wait_all(apps, sink: events)
        failed = wait_result.select { |r| r[:status] != "ok" }

        if failed.empty?
          apps.each do |name, slot|
            runner.adopt(slot[:item][:hostname], slot[:app], force: opts[:force],
              spec: { "dir" => File.expand_path(Dir.pwd), "proc" => name })
            routes_registered << { hostnames: slot[:item][:hostnames], app: slot[:app] }
            say opts, "  -> #{slot[:item][:url]}"
          end
        end
        finish_wait(ctx, resolved, apps, wait_result, failed, routes_registered,
          children, db_name, db_url, db_created, json: opts[:json])
      end

      # --wait epilogue. Success: the summary line and, with --json, the
      # success payload on stdout (the human summary moves to stderr so
      # stdout stays parseable). Failure: every spawned child is killed
      # and removed, the failed phase + that process's log tail is
      # reported, and start exits 1 — no half-booted routes left behind.
      def finish_wait(ctx, resolved, apps, wait_result, failed, routes_registered,
        children, db_name, db_url, db_created, json: false)
        urls = apps.transform_values { |slot| slot[:item][:url] }
        summary = "ready: #{urls.map { |n, u| "#{n}=#{u}" }.join(" ")}"

        if failed.empty?
          payload = Yamine::WaitPayload.success(resolved, wait_result, urls: urls,
            db_name: db_name, db_url: db_url, created: db_created)
          if json
            $stderr.puts summary
            puts JSON.generate(payload)
          else
            puts summary
          end
          return
        end

        apps.each_value { |slot| stop_spawned(slot[:app]) }
        children.each { |c| stop_spawned_pid(c[:pid]) }
        first = failed.first
        error = "Error: #{first[:name]} failed (#{first[:phase]}): #{first[:detail]}"
        payload = Yamine::WaitPayload.failure(resolved, wait_result, failed: first,
          log_tail: tail_for(first, apps))
        $stderr.puts error
        if json
          puts JSON.generate(payload)
        else
          $stderr.puts payload[:log_tail].to_s.lines.last(10).join if payload[:log_tail]
          $stderr.puts "Full log: #{payload[:log_path]}" if payload[:log_path]
        end
        cleanup_routes(ctx, apps.values.map { |slot| slot[:item][:hostname] })
        exit 1
      end

      def tail_for(failure, apps)
        name = failure[:name]
        slot = apps[name]
        path = slot ? File.expand_path(File.join(Dir.pwd, "log", "yamine-#{name}.log")) : nil
        lines = path && File.file?(path) ? File.readlines(path).last(20).join : "(no log file)"
        { path: path, tail: lines }
      rescue SystemCallError
        { path: path, tail: "(unreadable log)" }
      end

      def stop_spawned(app)
        stop_spawned_pid(app.pid)
      end

      def stop_spawned_pid(pid)
        Process.kill("TERM", pid)
      rescue SystemCallError
        nil
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
          database_url: db_url,
          extra_env: build_env(resolved, entry, proc_name: proc_name))
        children << { name: proc_name, pid: app.pid }
        say opts, "  [#{proc_name}] background (pid #{app.pid})"
      end

      # Refuse to boot over another agent's live routes unless forced.
      # Compares our worktree dir (spec.dir) against the owner's: same
      # dir + same agent is a restart, anything else names the owner.
      def check_worktree_ownership!(ctx, resolved, force:)
        return if force

        mine = Agent.name
        here = File.expand_path(Dir.pwd)
        # Stale pids (agent died, worktree deleted) must not block a restart.
        ctx.store.prune_stale
        Resolver.hostnames(resolved).each do |hostname|
          entry = ctx.store.find(hostname)
          next unless entry
          next unless entry["pid"] != 0 && ProxyControl.pid_alive?(entry["pid"])
          next if entry["agent"] == mine && entry.dig("spec", "dir") == here

          owner = entry["agent"] && !entry["agent"].empty? ? "agent #{entry["agent"].inspect}" : "PID #{entry["pid"]}"
          dir = entry.dig("spec", "dir")
          same_agent = entry["agent"] == mine
          same_dir = entry.dig("spec", "dir") == here
          if same_agent && !same_dir
            $stderr.puts "Error: #{hostname} was started from a different directory by the same agent #{mine.inspect}:"
            $stderr.puts "  running: #{dir || "(unknown)"}"
            $stderr.puts "  current: #{here}"
            $stderr.puts "  Stop the other instance first (`yamine stop` there) or take over explicitly:"
          else
            $stderr.puts "Error: #{hostname} is live and owned by #{owner}#{dir ? " (#{dir})" : ""}."
            $stderr.puts "  Work in your own worktree (each branch gets its own URL), or take over explicitly:"
          end
          $stderr.puts "    yamine start --force   (or bare `yamine --force`)"
          exit 1
        end
      end

      # The environment a process gets, from the config.
      #
      # Two levels, and the merge order is the point: top-level `env:`
      # describes the whole app (an API URL every process needs), a
      # process's own `env:` describes that process, and the process wins
      # where they collide — "this one worker talks to staging" should not
      # require restructuring the file.
      #
      # `env.clear` is literal values; `env.secret` names keys whose values
      # come from config/local.secrets (dotenv, gitignored), so a credential
      # stays out of the config file while still reaching the process. A
      # named secret that is missing is reported rather than silently
      # dropped: an app booting with a blank API key fails later, somewhere
      # far less obvious.
      def build_env(resolved, entry, proc_name: nil)
        env = {}

        top = resolved.env.is_a?(Hash) ? resolved.env : {}
        (top["clear"] || {}).each { |k, v| env[k] = v }

        entry_env = entry["env"] || {}
        (entry_env["clear"] || {}).each { |k, v| env[k] = v }

        secrets = resolved.secrets || {}
        (Array(top["secret"]) + Array(entry_env["secret"])).uniq.each do |key|
          if secrets.key?(key)
            env[key] = secrets[key]
          elsif ENV.key?(key)
            # Already in the environment (a shell export, an agent's
            # session) — the declaration is satisfied.
            env[key] = ENV[key]
          else
            label = proc_name ? "#{proc_name}: " : ""
            $stderr.puts "  #{label}warning: env.secret lists #{key}, but it is not in " \
                         "config/local.secrets (and not in the environment) — starting without it"
          end
        end

        env
      end

      # Rails env for database naming: RAILS_ENV when set, else development.
      # Non-Rails apps ignore it (their DATABASE_URL template decides).
      def rails_env
        ENV.fetch("RAILS_ENV", "development")
      end

      # Resolve this worktree's database, create it if missing, and run
      # the app's schema-load command on first creation. Returns
      # [created, url]: created is true only when this boot created the
      # database (so --wait can report provenance without a second
      # probe), url is nil when there is nothing to inject.
      #
      # Template sources: ENV DATABASE_URL, then config env.clear
      # DATABASE_URL (top-level env, falling back to per-process env
      # for configs written before top-level env existed). Injected
      # DATABASE_URL overrides database.yml/credentials at connection
      # time (ActiveRecord merges env over file config), so credentials
      # apps work — they just need the template declared in config.
      def setup_database(ctx, resolved, db_name, events: nil)
        return [false, nil] if db_opted_out?(resolved)

        template = ENV["DATABASE_URL"] || database_template_from_config(resolved)
        if template.nil? || template.strip.empty?
          warn_missing_template(resolved)
          return [false, nil]
        end

        url = Database.url_for(db_name, template)
        return [false, nil] unless url

        db_event = Readiness.phase(:db, "ensure #{db_name}", sink: events) do
          existed = Database.exists?(db_name, template)
          raise "database server unreachable — is postgres/mysql running?" unless Database.ensure_exists(db_name, template)

          existed ? "already exists" : "created #{db_name}"
        end
        unless db_event.status == "ok"
          $stderr.puts "  [db] WARNING: #{db_event.detail} — processes share the template database."
          return [false, nil]
        end
        created = db_event.detail.to_s.start_with?("created")

        schema_event = Readiness.phase(:schema, "load #{db_name}", sink: events) do
          next "skipped (already exists)" unless created

          run_schema_load(resolved, url)
        end
        unless schema_event.status == "ok"
          $stderr.puts "  [db] WARNING: schema load #{schema_event.status}: #{schema_event.detail}."
        end
        [created, url]
      end

      # Top-level `db: false` opts out of per-worktree databases.
      # (A `db` process entry still boots as a process — only the
      # explicit top-level key opts out.)
      def db_opted_out?(resolved)
        resolved.db == false
      end

      # The dangerous case made loud: the app looks database-backed
      # (server adapter in database.yml, or pg/mysql2 in the Gemfile)
      # but no template was declared, so every worktree would silently
      # share one database. Name the fix; do not guess.
      def warn_missing_template(resolved)
        return unless database_backed?

        $stderr.puts "  [db] WARNING: app looks database-backed but no DATABASE_URL template found."
        $stderr.puts "    Each worktree would share one database. Declare the template in config/local.yml:"
        $stderr.puts "      env:"
        $stderr.puts "        clear:"
        $stderr.puts "          DATABASE_URL: postgres://user@localhost:5432/myapp_development"
        $stderr.puts "    (password via config/local.secrets + env.secret), or opt out with top-level `db: false`."
      end

      # Heuristics, deliberately conservative: only warn when there is
      # positive evidence of a server database. SQLite-only and
      # database-less apps stay silent.
      def database_backed?
        database_yml_server? || gemfile_server_adapter?
      end

      def database_yml_server?(path = File.join(Dir.pwd, "config", "database.yml"))
        return false unless File.file?(path)

        content = File.read(path)
        content.match?(/adapter:\s*(postgresql|postgres|postgis|mysql2?|trilogy)/i)
      rescue SystemCallError
        false
      end

      def gemfile_server_adapter?(path = File.join(Dir.pwd, "Gemfile"))
        return false unless File.file?(path)

        content = File.read(path)
        content.match?(/gem\s+["'](pg|mysql2|trilogy)["']/)
      rescue SystemCallError
        false
      end

      def database_template_from_config(resolved)
        top = resolved.env.is_a?(Hash) ? resolved.env["clear"] : nil
        from_top = top.is_a?(Hash) ? top["DATABASE_URL"] : nil
        return from_top if from_top && !from_top.to_s.strip.empty?

        env = resolved.processes.values.map { |e| e["env"] || {} }
        clear = env.map { |e| e["clear"] || {} }.reduce({}, :merge)
        clear["DATABASE_URL"]
      end

      # Schema-load on first boot uses the app's own command when declared
      # (top-level db.schema_load in config/local.yml), else a Rails
      # default when a Rails app is detected, else nothing (frameworks
      # without a schema concept need no step). Returns a detail string.
      def run_schema_load(resolved, url)
        cmd = db_schema_load(resolved) ||
          ("bin/rails db:schema:load" if rails_app?)
        return "no schema-load command" unless cmd

        ok = system({ "DATABASE_URL" => url, "RAILS_ENV" => rails_env },
          "sh", "-c", cmd, chdir: Dir.pwd, out: File::NULL, err: File::NULL)
        ok ? "loaded schema via #{cmd}" : raise("schema-load exited non-zero: #{cmd}")
      end

      def db_schema_load(resolved)
        resolved.db.is_a?(Hash) ? resolved.db["schema_load"] : nil
      end

      def rails_app?
        File.file?(File.join(Dir.pwd, "config", "application.rb"))
      end

      # Supervise the booted tree: the first child to exit ends the run,
      # because a half-stack is worse than no stack — a dead jobs worker
      # with a live web process looks healthy until someone wonders why
      # nothing is being processed. Name the casualty and its log: "a
      # process exited" left the user to guess which one, and the log
      # worth reading is per-process.
      def supervise_tree(ctx, hostnames, named_pids, reporter: nil)
        loop do
          sleep 0.5
          dead = named_pids.find { |pid, _| !ProxyControl.pid_alive?(pid) }
          if dead
            pid, name = dead
            $stderr.puts "\n[#{name}] exited (pid #{pid}) — stopping the whole tree."
            log = File.join(Dir.pwd, "log", "yamine-#{name}.log")
            $stderr.puts "  log: #{log}" if File.file?(log)
            reporter&.note("#{name} exited; cleaning up routes")
            cleanup_routes(ctx, hostnames)
            # Kill remaining children
            named_pids.each_key do |other|
              Process.kill("TERM", other) rescue nil
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

      def resolve!(ctx, variant: nil, tld: nil, use_branch: false)
        # The resolver calls Config.load, which raises ConfigError if
        # config/local.yml is missing — exactly what we want.
        Yamine::Resolver.resolve(Dir.pwd, variant: variant, tld: tld, use_branch: use_branch)
      end

      # json: keeps stdout free for the machine-readable stream — this runs
      # BEFORE boot_all installs the reporter, so its progress line is the
      # one piece of narration that could still land mid-JSON and break a
      # parser on the first line of a --json run.
      def ensure_proxy!(ctx, json: false)
        port = ctx.proxy_port
        tls = ctx.proxy_tls
        if ProxyControl.listening?(port)
          if ProxyControl.ours?(port, tls: tls)
            warn_non_default_port(port, tls)
            return
          end
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
        starting = "Starting proxy#{privileged ? " (sudo)" : ""}..."
        json ? $stderr.puts(starting) : puts(starting)
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

      # yamine's whole promise is a bare https://<app>.localhost. An
      # already-running proxy on another port silently defeats it: every
      # URL grows a :1355, which then leaks into OAuth callbacks, mailer
      # hosts, and webhooks. The port file is machine-wide state, so a
      # single `-p 1355` run (CI, a sandbox, a gem-dev foreground proxy)
      # downgrades every project on the machine until someone notices.
      #
      # Not an error: CI and sandboxes opt into a port deliberately, and
      # refusing would break them. So: proceed, but say plainly what the
      # URL will look like and how to get the clean one back.
      def warn_non_default_port(port, tls)
        return if ENV["YAMINE_PORT"] && ENV["YAMINE_PORT"].to_i == port
        notice = ProxyControl.port_notice(port, tls)
        return unless notice

        $stderr.puts "Warning: #{notice}"
      end
    end
  end
end

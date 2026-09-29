# frozen_string_literal: true

module Yamine
  class CLI
    # Boot commands: `yamine`, `yamine start`, `yamine run`.
    # The config file is mandatory — missing file prints the fix and exits.
    # `boot_all` fans out over every process declared in config/local.yml.
    # No inference, no Procfile at boot, no single-process default.
    module BootCommand
      PORT_IGNORING = %w[jekyll middleman bridgetown].freeze
      # How long the detaching process waits for the app to answer before
      # it reports that it did not. Generous on purpose: the boot running
      # inside the child has its own budget per phase (Readiness's, 45s a
      # process, plus deps/db/schema), and this is the parent giving up
      # on a child still doing legitimate work. A boot that fails ends
      # the wait on its own, long before this.
      DETACH_TIMEOUT = 300

      module_function

      # Bare `yamine` / `yamine start` / `yamine run`.
      # Reads config/local.yml via the resolver, ensures the proxy,
      # boots every process, supervises the tree, cleans up on exit.
      def run_inferred(ctx, args)
        variant = ENV["YAMINE_VARIANT"]
        opts = ctx.parse_flags(args, %i[variant tld force app_port wait no_wait json branch detach])
        resolved = resolve!(ctx, variant: opts[:variant] || variant, tld: opts[:tld],
          use_branch: opts[:branch])
        # Ownership gate before any side effects: no proxy spawn, no
        # port allocation when we'd refuse anyway.
        check_worktree_ownership!(ctx, resolved, force: opts[:force])
        return detach_boot(ctx, resolved, opts) if opts[:detach]

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

        # Per-worktree databases: one isolated set per directory so
        # concurrent agents never share tables — every database the app
        # declares (a Rails multi-database app may have five). The
        # claim records the whole set; setup creates what's missing,
        # loads schemas on first creation, and hands back the env to
        # inject into every process. SQLite needs nothing (relative
        # paths already isolate); the branch plays no part (dirs are
        # stable, branches hop).
        db_name = Database.name_for(Dir.pwd, env: rails_env,
          state_dir: ctx.store.dir)
        db_created, db_env = setup_database(ctx, resolved, db_name, events: events)
        events&.note("[db] #{db_name}#{db_created ? " (created)" : ""}") if db_env && !db_env.empty?

        with_wait = !opts[:no_wait]
        spawn_plan = collect_spawns(ctx, runner, resolved, opts, db_env, children)

        begin
          if with_wait
            boot_concurrent(ctx, runner, resolved, opts, spawn_plan, children,
              routes_registered, db_env, db_name, db_created, events: events)
          else
            boot_sequential(ctx, runner, resolved, opts, spawn_plan, children,
              routes_registered, db_env, events: events)
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
        ctx.report_resolution_gaps(routes_registered.flat_map { |r| r[:hostnames] })

        # Supervisor: exit when ANY child dies (loud cleanup). pid => name
        # so the message names the casualty instead of "a process".
        named_pids = {}
        routes_registered.each { |r| named_pids[r[:app].pid] = r[:app].name }
        children.each { |c| named_pids[c[:pid]] = c[:name] }
        all_hostnames = routes_registered.flat_map { |r| r[:hostnames] }
        # Nothing to supervise is not a boot. collect_spawns refuses a
        # compound cmd line with an error and leaves the plan empty, and
        # the boot then printed `ready: ` and sat in supervise_tree for
        # ever with an empty pid map — a hang indistinguishable from a
        # healthy start, and one `--detach` would have made its caller
        # wait out. The errors above it name the process it refused.
        if named_pids.empty?
          $stderr.puts "Error: no process was started — see the errors above."
          exit 1
        end
        trap_cleanup(ctx, all_hostnames, named_pids.keys)
        supervise_tree(ctx, all_hostnames, named_pids, reporter: events,
          json: opts[:json])
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
      def collect_spawns(ctx, runner, resolved, opts, db_env, children)
        plan = []
        processes = resolved.processes
        processes.each do |proc_name, entry|
          hostname = Resolver.hostname_for(resolved, proc_name)
          if entry["proxy"] == false
            boot_background(ctx, runner, resolved, proc_name, entry, opts,
              children, db_env)
            next
          end
          next unless hostname

          url = Hostname.url(hostname, port: ctx.proxy_port, tls: ctx.proxy_tls)
          cmd = entry["cmd"].to_s
          if cmd.match?(Yamine::Procfile::COMPOUND)
            $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — split it into separate processes, or wrap in a script and point cmd: at it"
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
        routes_registered, db_env, events: nil)
        plan.each do |item|
          say opts, "  [#{item[:name]}] #{item[:url]}"
          # Always allow the proxied hostname in Rails dev (Rails ignores
          # this env var when not a Rails app — safe for every framework).
          # db_env points every process at this worktree's own databases;
          # non-Ruby frameworks that honor DATABASE_URL get isolation for
          # free, others ignore it. boot_run registers the route + backend
          # sidecar itself (register: true default); no separate adopt
          # step needed.
          app = runner.boot_run(name: item[:name], hostname: item[:hostname],
            url: item[:url], dir: Dir.pwd, command: item[:command],
            port: item[:port], force: opts[:force],
            rails_dev_host: item[:hostname], database_env: db_env,
            subdomains: resolved.subdomains,
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
        routes_registered, db_env, db_name, db_created, events: nil)
        apps = {}
        plan.each do |item|
          say opts, "  [#{item[:name]}] #{item[:url]}"
          app = runner.spawn_http(name: item[:name], hostname: item[:hostname],
            url: item[:url], dir: Dir.pwd, command: item[:command],
            port: item[:port], rails_dev_host: item[:hostname],
            database_env: db_env, force: opts[:force],
            extra_env: build_env(resolved, item[:entry], proc_name: item[:name]))
          # Tracked before registration so any later failure (a raise
          # during adopt, a crash while another process waits) can
          # always reap it. Duplicate names in named_pids are harmless.
          children << { name: item[:name], pid: app.pid }
          apps[item[:name]] = {
            item: item,
            log_path: File.join(Dir.pwd, "log", "development.log"),
            app: app
          }
        end
        wait_result = Readiness.wait_all(apps, sink: events)
        failed = wait_result.select { |r| r[:status] != "ok" }

        if failed.empty?
          apps.each do |name, slot|
            runner.adopt(slot[:item][:hostname], slot[:app], force: opts[:force],
              spec: { "dir" => File.expand_path(Dir.pwd), "proc" => name },
              subdomains: resolved.subdomains)
            routes_registered << { hostnames: slot[:item][:hostnames], app: slot[:app] }
            say opts, "  -> #{slot[:item][:url]}"
          end
        end
        finish_wait(ctx, resolved, apps, wait_result, failed, routes_registered,
          children, db_name, db_env, db_created, json: opts[:json])
      end

      # --wait epilogue. Success: the summary line and, with --json, the
      # success payload on stdout (the human summary moves to stderr so
      # stdout stays parseable). Failure: every spawned child is killed
      # and removed, the failed phase + that process's log tail is
      # reported, and start exits 1 — no half-booted routes left behind.
      def finish_wait(ctx, resolved, apps, wait_result, failed, routes_registered,
        children, db_name, db_env, db_created, json: false)
        urls = apps.transform_values { |slot| slot[:item][:url] }
        summary = "ready: #{urls.map { |n, u| "#{n}=#{u}" }.join(" ")}"

        if failed.empty?
          payload = Yamine::WaitPayload.success(resolved, wait_result, urls: urls,
            db_name: db_name, db_url: db_env && db_env["DATABASE_URL"],
            created: db_created)
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
        # Every process appends to the same file, so the app slot only
        # decides whether there is a process to blame for it.
        path = apps[failure[:name]] ? app_log_path : nil
        { path: path, tail: path ? log_tail(path) : "(no log file)" }
      end

      def stop_spawned(app)
        stop_spawned_pid(app.pid)
      end

      # The pid of a spawned process is its `sh -c` shell, so the whole
      # group gets the signal: the app behind the shell is what must
      # actually stop. Falls back to the single pid for a process that
      # leads no group, and never raises (see ProcessTree).
      #
      # Escalated, because this is the "a failure leaves nothing running"
      # contract and asking is not enough: a shell still assembling its
      # tree forks the app after the signal sweep, and that app is then
      # unreachable by the signal that was just sent to its group
      # (ProcessTree.terminate). The signal-trap path stays on the
      # single-shot `term` — a trap handler must not sleep.
      def stop_spawned_pid(pid)
        ProcessTree.terminate(pid)
      end

      # A background process (proxy: false) is spawned, logged, and
      # supervised exactly like an HTTP one — it just gets no route.
      def boot_background(ctx, runner, resolved, proc_name, entry, opts, children, db_env)
        cmd = entry["cmd"].to_s
        if cmd.match?(Yamine::Procfile::COMPOUND)
          $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — split it into separate processes, or wrap it in a script and point cmd: at it"
          return
        end
        port = opts[:app_port] || Ports.find_free
        url = "background://#{resolved.app}/#{proc_name}"
        app = runner.boot_run(name: proc_name, hostname: "#{resolved.app}.#{proc_name}.internal",
          url: url, dir: Dir.pwd, command: ["sh", "-c", cmd], port: port,
          force: opts[:force], rails_dev_host: nil, register: false,
          database_env: db_env,
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

      # Resolve this checkout's databases, create what's missing, and
      # run the app's schema-load command on first creation. Returns
      # [created, env]: created is true only when this boot created a
      # database (so --wait can report provenance without a second
      # probe), env is the hash of variables to inject into every
      # process (DATABASE_URL for primary, NAME_DATABASE_URL for the
      # rest — Rails' own convention) or nil when there is nothing to
      # inject.
      #
      # Three shapes, decided in order:
      #   * a multi-database claim (worktree recorded at add time) —
      #     the whole set is ensured and injected;
      #   * the main checkout with no template — nothing to isolate:
      #     the app's own databases ARE its databases. Silence, not
      #     the old false alarm;
      #   * a DATABASE_URL template (ENV or config env.clear) — the
      #     single-database path, unchanged. Injected DATABASE_URL
      #     overrides database.yml/credentials at connection time
      #     (ActiveRecord merges env over file config), so credentials
      #     apps work — they just need the template declared in config.
      def setup_database(ctx, resolved, db_name, events: nil)
        return [false, nil] if db_opted_out?(resolved)

        claim = Database.multi_claim(ctx.store.dir, db_name)
        return setup_multidb(resolved, claim, events: events) if claim

        template = ENV["DATABASE_URL"] || database_template_from_config(resolved)
        if template.nil? || template.strip.empty?
          if Database.main_checkout?(Dir.pwd) && rails_app?
            Readiness.phase(:db, "main checkout — the app's own databases", sink: events) do
              "unsuffixed; worktrees get isolated sets at `yamine worktree add`"
            end
            return [false, nil]
          end

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

        db_env = { "DATABASE_URL" => url }
        schema_event = Readiness.phase(:schema, "load #{db_name}", sink: events) do
          next "skipped (already exists)" unless created

          run_schema_load(resolved, db_env)
        end
        unless schema_event.status == "ok"
          $stderr.puts "  [db] WARNING: schema load #{schema_event.status}: #{schema_event.detail}."
        end
        [created, db_env]
      end

      # Multi-database worktree: the claim carries every database name
      # plus the app's own URL for each. Create what's missing, hand
      # back the env for the whole set, load schemas once on first
      # creation.
      #
      # On creation failure the env is STILL handed back. A boot
      # pointed at missing databases fails loudly at connect time,
      # while a boot falling back to the shared base databases would
      # silently run another checkout's tables — the exact bug
      # isolation exists to kill. Loud and broken beats quiet and
      # wrong.
      def setup_multidb(resolved, claim, events: nil)
        names = claim["names"]
        bases = claim["bases"] || {}
        env = db_env_for(names, bases)
        created = false

        db_event = Readiness.phase(:db, "ensure #{names.size} databases", sink: events) do
          missing = names.reject { |cfg, actual| Database.exists?(actual, base_for(bases, cfg)) }
          failed = missing.filter_map do |cfg, actual|
            actual unless Database.ensure_exists(actual, base_for(bases, cfg))
          end
          raise "could not create #{failed.join(', ')} — is postgres/mysql running?" unless failed.empty?

          created = missing.any?
          created ? "created #{missing.size}" : "already exist"
        end
        unless db_event.status == "ok"
          $stderr.puts "  [db] WARNING: #{db_event.detail}."
          $stderr.puts "    The isolated URLs stay in effect — the app cannot connect until they exist."
          $stderr.puts "    Start the database server and re-run `yamine start`."
        end

        if created
          schema_event = Readiness.phase(:schema, "load #{names.size} schemas", sink: events) do
            run_schema_load(resolved, env)
          end
          unless schema_event.status == "ok"
            $stderr.puts "  [db] WARNING: schema load #{schema_event.status}: #{schema_event.detail}."
          end
        end
        [created, env]
      end

      # The env for a whole claim: DATABASE_URL for primary (the name
      # every non-Rails framework reads too), NAME_DATABASE_URL per
      # config — Rails resolves those over database.yml all by
      # themselves, so even an app whose database.yml never heard of
      # yamine gets full isolation in supervised processes.
      def db_env_for(names, bases)
        names.each_with_object({}) do |(cfg, actual), env|
          url = Database.url_for(actual, base_for(bases, cfg))
          next unless url

          env["DATABASE_URL"] = url if cfg == "primary"
          env["#{cfg.upcase}_DATABASE_URL"] = url
        end
      end

      # All of an app's databases live on one server in every layout
      # yamine has seen; a per-config base with a missing entry falls
      # back to the first.
      def base_for(bases, cfg)
        bases[cfg] || bases.values.first
      end

      # Worktree-add (and `yamine db create` in a worktree): turn a
      # probe of the app's real databases into a provisioned,
      # self-describing claim. Names come from the app, the suffix
      # from the directory; claim + .env files are written BEFORE any
      # database is created, so a failure mid-way leaves a state the
      # next `yamine db create` or boot can finish from — never a
      # half-named set with no record of it.
      #
      # Returns the final names; raises Error only for conditions the
      # user must fix (name budget, server down, .env breaking the
      # app's boot) — those keep the worktree and the claim.
      def provision_multidb(ctx, dir, claim_key, rows)
        env_name = rails_env
        # Re-provisioning a worktree whose .env exists: the app (via
        # dotenv) resolves SUFFIXED names — strip the claim's stored
        # suffix before fitting, or this pass would double it and
        # yamine would provision a set the app never connects to.
        prior = Database.load_map(ctx.store.dir)[claim_key]
        prior_suffix = prior.is_a?(Hash) ? prior["suffix"] : nil
        rows = strip_suffix(rows, prior_suffix)
        # The test environment's database joins the claim: worktree
        # tests run against it (.env.test carries its URL), and
        # teardown must drop it — a leaked test database per worktree
        # is exactly the leftover this exists to prevent. Test configs
        # are flat (implicitly named "primary"), so the claim key is
        # namespaced under "test" to not collide with the dev primary.
        # A test env the app cannot answer (missing test credentials,
        # say) degrades to a dev-only claim; `yamine db create` heals.
        test_rows = Probe.rails_databases(dir, env: "test")
        test_rows = strip_suffix(test_rows, prior_suffix)
        test_pairs = (test_rows && Probe.server_backed(test_rows) || [])
          .map { |r| [env_namespaced_key(r["name"], "test"), r] }

        bases = rows.to_h { |r| [r["name"], r["url"]] }
          .merge(test_pairs.to_h { |key, r| [key, r["url"]] })
        suffix = Database.suffix_for(claim_key, env_name)
        all_bases = rows.map { |r| r["database"] } + test_pairs.map { |_, r| r["database"] }
        fitted = Database.fit_suffix(suffix, dir, all_bases)
        unless fitted
          longest = all_bases.max_by(&:to_s)&.bytesize
          raise Error,
            "a database name of #{longest} bytes leaves no room for a worktree " \
            "suffix (#{Database::MAX_IDENTIFIER_BYTES}-byte limit): #{all_bases.inspect}\n" \
            "  Shorten the base names in the app's database configuration."
        end
        names = rows.to_h { |r| [r["name"], Database.multiname(r["database"], fitted)] }
          .merge(test_pairs.to_h { |key, r| [key, Database.multiname(r["database"], fitted)] })

        map = Database.load_map(ctx.store.dir)
        map[claim_key] = (map[claim_key] || {}).merge(
          "dir" => File.expand_path(dir),
          "claimed_at" => Time.now.utc.iso8601,
          "suffix" => fitted, "names" => names, "bases" => bases)
        Database.save_map(ctx.store.dir, map)
        # The environment files: what hand-run commands read. Written
        # before creation so the verify probe below can see them.
        dev_env = db_env_for(
          names.reject { |cfg, _| cfg == "test" || cfg.start_with?("test_") }, bases)
        test_url = names["test"] &&
          Database.url_for(names["test"], base_for(bases, "test"))
        Database.write_env_files(dir, dev_env, test_url: test_url)
        Database.exclude_files(dir, Database::ENV_FILES)

        # An empty test database is worse than none: Rails won't
        # auto-load schema into it (verified — first `rails test`
        # fails on missing schema_migrations, not a clear
        # NoDatabaseError). So when THIS pass created the test DB,
        # prepare it too — after that, tests just run.
        test_needs_schema = names["test"] &&
          !Database.exists?(names["test"], base_for(bases, "test"))

        Dir.chdir(dir) { setup_database(ctx, Resolver.resolve(dir), claim_key) }

        missing = names.reject { |cfg, actual| Database.exists?(actual, base_for(bases, cfg)) }
        unless missing.empty?
          raise Error,
            "could not create #{missing.values.join(', ')} — is the database server running?\n" \
            "  The worktree and its claim are kept; start postgres/mysql and run `yamine db create` here."
        end

        if test_needs_schema
          # RAILS_ENV=test, not development: dotenv must load .env.test
          # (PRIMARY_DATABASE_URL = this worktree's test URL) AND the
          # environment-override merge only applies to the CURRENT
          # env's configs — under development the flat test config
          # would resolve to the base name and purge+load the MAIN
          # checkout's test database instead of this worktree's.
          prepared = Dir.chdir(dir) do
            system({ "RAILS_ENV" => "test" }, "sh", "-c", "bin/rails db:test:prepare",
              out: File::NULL, err: File::NULL)
          end
          if prepared
            puts "  test database schema ready — tests run as-is"
          else
            warn "  WARNING: could not prepare the test database — run `bin/rails db:test:prepare` in #{dir} before running tests"
          end
        end

        verify_env_loading(dir, names)
        names
      end

      def strip_suffix(rows, suffix)
        return rows if rows.nil? || suffix.nil? || suffix.empty?

        rows.map do |r|
          if r["database"].end_with?("_#{suffix}")
            r.merge("database" => r["database"].delete_suffix("_#{suffix}"))
          else
            r
          end
        end
      end

      # Flat configs (a lone `test:` section) resolve as "primary" —
      # the claim key must not collide with the development primary.
      def env_namespaced_key(cfg_name, env)
        cfg_name == "primary" ? env : "#{env}_#{cfg_name}"
      end

      # The proof, not the promise: re-probe now that .env exists.
      # Matching names mean something inside the app loads .env
      # (dotenv-rails or any dotenv loader) — hand-run console/test/
      # migrate commands are isolated too. Mismatch is not fatal
      # (supervised boots isolate via injected env regardless), but
      # it is the one gap worth shouting about at the exact moment of
      # creation. A probe that cannot run at all after writing .env
      # IS fatal: the app no longer boots, and .env's own authorship
      # is the likely reason.
      def verify_env_loading(dir, names)
        rows = Probe.rails_databases(dir)
        unless rows
          raise Error,
            "the app no longer boots after writing .env — " \
            "check the generated .env files in #{dir}"
        end

        actual = rows.to_h { |r| [r["name"], r["database"]] }
        # Keys absent from this probe are env-namespaced (the test
        # database, probed separately) — the dev probe cannot vouch
        # for them either way; skip, don't flag.
        mismatched = names.reject { |cfg, want| !actual.key?(cfg) || actual[cfg] == want }
        if mismatched.empty?
          puts "  .env loaded — hand-run commands are isolated too"
        else
          cfg, want = mismatched.first
          env_url = rows.first["env_database_url"]
          if env_url && !env_url.empty?
            # The loader DID run — DATABASE_URL reached the app — yet
            # resolution ignored it. database.yml supplies `url:` keys
            # (credentials-style), and for those Rails gives the FILE
            # precedence: merge_db_environment_variables skips configs
            # that are already URL-shaped. No environment channel,
            # spawned or loaded, can redirect this app in that form.
            warn "  WARNING: #{cfg} resolves to #{actual[cfg].inspect} even though " \
                 "DATABASE_URL says #{env_url.split("/").last.inspect}."
            warn "    database.yml's `url:` keys take precedence over the environment in this configuration —"
            warn "    neither injected env nor .env can redirect them. Switch development/test to"
            warn "    component form (database:, host:, username:) so DATABASE_URL and .env apply —"
            warn "    see the yamine README's multi-database section."
          else
            warn "  WARNING: this app does not load .env " \
                 "(#{cfg} resolves to #{actual[cfg].inspect}, expected #{want.inspect})."
            warn "    Supervised boots are still isolated via injected env, but `rails console`, " \
                 "`rails test`, and `db:migrate` run by hand in this worktree would use the main checkout's databases."
            warn "    Fix once: add `gem \"dotenv-rails\", groups: [:development, :test]` to the Gemfile — " \
                 "any dotenv loader works."
          end
        end
      rescue StandardError => e
        raise Error, e.message if e.is_a?(Error)

        raise Error,
          "the app no longer boots after writing .env: #{e.message}"
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
        Database.template_for(resolved)
      end

      # Schema-load on first boot uses the app's own command when declared
      # (top-level db.schema_load in config/local.yml), else a Rails
      # default when a Rails app is detected, else nothing (frameworks
      # without a schema concept need no step). db_env is the whole
      # injection hash — with a multi-database claim, Rails' schema
      # tasks iterate every config and each resolves to its own
      # isolated database. Returns a detail string.
      def run_schema_load(resolved, db_env)
        cmd = db_schema_load(resolved) ||
          ("bin/rails db:schema:load" if rails_app?)
        return "no schema-load command" unless cmd

        env = { "RAILS_ENV" => rails_env }.merge(db_env || {})
        ok = system(env,
          "sh", "-c", cmd, chdir: Dir.pwd, out: File::NULL, err: File::NULL)
        ok ? "loaded schema via #{cmd}" : raise("schema-load exited non-zero: #{cmd}")
      end

      def db_schema_load(resolved)
        resolved.db.is_a?(Hash) ? resolved.db["schema_load"] : nil
      end

      def rails_app?
        File.file?(File.join(Dir.pwd, "config", "application.rb"))
      end

      # `yamine start --detach`: boot into the background and hand control
      # back, so an agent gets its prompt (and its exit code) without
      # reaching for nohup.
      #
      # The route's recorded owner pid is the thing this has to get
      # right, and it is why the boot happens in the child and never in
      # the parent: `add_route` records `Process.pid`, and
      # RouteStore#load_routes prunes every route whose pid is dead. A
      # parent that registered the routes and exited would have its own
      # route pruned on the next read, and the proxy would 503 an app
      # that is running perfectly well. So the child boots — its pid is
      # what lands in routes.json — keeps the tree supervised, and
      # outlives this process. The parent only waits and reports.
      def detach_boot(ctx, resolved, opts)
        hostname = Resolver.hostname_for(resolved, Resolver.primary_proc(resolved))
        raise Error, "no HTTP process (proxy: true) in config/local.yml to detach" unless hostname

        url = Hostname.url(hostname, port: ctx.proxy_port, tls: ctx.proxy_tls)
        pidfile, log = detach_paths(ctx.store, hostname)
        running = detached_pid(pidfile) || foreground_owner(ctx, hostname)
        return report_detached(hostname, url, log, running, opts, started: false) if running

        # Ensured here, in the process still attached to the caller: a
        # sudo prompt, a port clash or a missing setup has to be reported
        # by something whose exit code and output the caller can see.
        ensure_proxy!(ctx, json: opts[:json])
        pid = fork { detached_child(ctx, resolved, opts, hostname, pidfile, log) }
        await_detached(ctx, hostname, url, log, pid, opts)
      end

      # Detach bookkeeping under the state dir, beside the routes the
      # tree owns. The pidfile is the only record of WHICH process
      # supervises a detached tree (routes.json holds the app's route and
      # `yamine stop` reaches the backend through the sidecar), which is
      # also what makes a second `--detach` a no-op instead of a second
      # app fighting over the same hostname.
      def detach_paths(store, hostname)
        [File.join(store.dir, "start-#{hostname}.pid"),
         File.join(store.dir, "start-#{hostname}.log")]
      end

      # The pid of a detached tree, or nil. A pidfile whose process is
      # gone is not a tree — it is a crash or a stop that never got to
      # clean up — and reading it as one would make `--detach` refuse to
      # start anything on that hostname again.
      def detached_pid(pidfile)
        return nil unless File.file?(pidfile)

        pid = File.read(pidfile).strip.to_i
        pid.positive? && ProxyControl.pid_alive?(pid) ? pid : nil
      rescue SystemCallError, ArgumentError
        nil
      end

      # A foreground `yamine start` in this directory has no pidfile, so
      # the route it registered is the other record of a tree already
      # running here. Without this, `--detach` beside a live foreground
      # boot would fork, lose the race for the route, and report a boot
      # failure for an app that is up and serving.
      def foreground_owner(ctx, hostname)
        entry = ctx.store.find(hostname)
        return nil unless entry && entry["pid"] != 0
        return nil unless entry["agent"] == Agent.name
        return nil unless entry.dig("spec", "dir") == File.expand_path(Dir.pwd)

        ProxyControl.pid_alive?(entry["pid"]) ? entry["pid"] : nil
      end

      # The detached half: its own session, its own stdio, and the whole
      # boot. `setsid` so the tree outlives the shell that started it and
      # takes no SIGHUP from a terminal about to close; the log file so
      # the boot's narration, and the message that ends the run, have
      # somewhere to land once this process is gone.
      def detached_child(ctx, resolved, opts, hostname, pidfile, log)
        Process.setsid
        redirect_detached_io(log)
        File.write(pidfile, "#{Process.pid}\n")
        # `--no-wait` has nothing left to say here: the promise of
        # detaching is that the command returns once the app answers, so
        # the child always takes the health-gated path.
        boot_all(ctx, resolved, opts.merge(no_wait: nil, detach: nil))
      rescue SystemExit => e
        # The boot exits on purpose — a failed health wait, a child that
        # died, a signal from `yamine stop` — and that status is the only
        # report there will ever be. `exit!` rather than `exit` because a
        # forked block turns a raise into a generic failure, and rather
        # than a normal exit because the pidfile is ours to remove: a
        # dead tree must not leave a pidfile claiming one is running.
        detach_forget(pidfile)
        exit!(e.status)
      rescue StandardError => e
        $stderr.puts "[yamine] detached boot failed: #{e.message.lines.first&.strip}"
        detach_forget(pidfile)
        exit!(1)
      end

      # stdin from /dev/null so a read never blocks on a terminal that
      # has gone away; both streams into the log; sync, because a
      # buffered stream in a process that may live for hours is a log
      # that shows nothing until it exits.
      def redirect_detached_io(log)
        io = Log.open_append(log)
        $stdin.reopen(File::NULL)
        $stdout.reopen(io)
        $stderr.reopen(io)
        $stdout.sync = $stderr.sync = true
      ensure
        io&.close
      end

      # Remove the pidfile, but only while it is still ours: a second
      # `--detach` that already replaced the file must not have its
      # record deleted by the first tree's cleanup.
      def detach_forget(pidfile)
        return unless File.read(pidfile).strip.to_i == Process.pid

        FileUtils.rm_f(pidfile)
      rescue SystemCallError
        nil
      end

      # Wait for the app to answer, then say what happened. Two things
      # end the wait: the route appears — which on the health-gated path
      # means every process passed its check, since the child registers
      # nothing until they all do — or the child exits, which is a boot
      # that failed and has already written why into the log.
      #
      # The route's recorded pid is what proves it is THIS child's: a
      # route left over from an earlier run would otherwise pass for a
      # successful boot of one that never happened.
      def await_detached(ctx, hostname, url, log, pid, opts)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DETACH_TIMEOUT
        status = nil
        loop do
          entry = ctx.store.find(hostname)
          return report_detached(hostname, url, log, pid, opts, started: true) if
            entry && entry["pid"] == pid
          # WNOHANG, and it has to be a wait: the child is this
          # process's own child, so a dead one sits in the process table
          # as a zombie until it is reaped and `kill(0, pid)` would
          # report it alive for as long as we sat here waiting.
          _waited, status = Process.waitpid2(pid, Process::WNOHANG)
          break if status
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            status = :timeout
            break
          end

          sleep 0.25
        end
        detach_failed(hostname, url, log, status, opts)
      end

      # The report on success, and the report on "was already up": the
      # URL, the pid that owns the tree, and where its output goes.
      # `--json` gets the same three as a payload, because an agent's
      # next move is `yamine list` and "started" with no pid to stop
      # again is not a usable answer.
      def report_detached(hostname, url, log, pid, opts, started:)
        payload = { ok: true, url: url, hostnames: [hostname], pid: pid,
          log_path: log, started: started }
        if opts[:json]
          puts JSON.generate(payload)
          return
        end
        if started
          puts "Detached: #{url}"
        else
          puts "Already running: #{url} (pid #{pid})"
          puts "  Nothing was started; `yamine stop` stops this one."
          return
        end
        puts "  pid  #{pid}"
        puts "  log  #{log}"
      end

      # Never zero, and never "started". The reason it is not serving is
      # in the log and nowhere else, so that is where the report points.
      def detach_failed(hostname, url, log, status, opts)
        reason =
          case status
          when :timeout then "did not become healthy within #{DETACH_TIMEOUT}s"
          when nil then "was killed before serving"
          else "exited (#{describe_status(status)})"
          end
        payload = { ok: false, url: url, hostnames: [hostname], reason: reason,
          log_path: log, log_tail: log_tail(log) }
        if opts[:json]
          $stderr.puts "Error: yamine start --detach: #{hostname} #{reason}."
          puts JSON.generate(payload)
        else
          $stderr.puts "Error: yamine start --detach: #{hostname} #{reason}."
          $stderr.puts log_tail(log, lines: 10)
          $stderr.puts "  log: #{log}"
        end
        exit 1
      end

      # The one log every process in a tree appends to (Runner#log_path),
      # so it is also the one log worth reading when a child dies.
      def app_log_path
        File.expand_path(File.join(Dir.pwd, "log", "development.log"))
      end

      # Last lines of the app log, for failure payloads and for the
      # message that ends a run. Never raises: a missing or unreadable
      # log is part of the failure being reported, not a second failure.
      def log_tail(path = app_log_path, lines: 20)
        return "(no log file)" unless File.file?(path)

        File.readlines(path).last(lines).join
      rescue SystemCallError
        "(unreadable log)"
      end

      # What a pid we spawned exited with, in words an agent can read:
      # a code, or the signal that took it down. A pid with no status to
      # report (never ours, not yet reaped) says so rather than guessing
      # a code.
      def describe_status(status)
        return "status unknown" unless status
        return "signal #{status.termsig}" if status.signaled?

        "exit #{status.exitstatus}"
      end

      # Supervise the booted tree: the first child to exit ends the run,
      # because a half-stack is worse than no stack — a dead jobs worker
      # with a live web process looks healthy until someone wonders why
      # nothing is being processed. Name the casualty, its status and its
      # log: "a process exited" left the user to guess which one, and the
      # log worth reading is the one every process appends to.
      #
      # The status is 1, never 0. `yamine start` is how an agent decides
      # whether the app came up, and a zero here reads as "healthy": the
      # routes are already removed, the rest of the tree is being killed,
      # and the app is not serving. An agent that trusted it would go on
      # to curl a URL that answers 503 and blame the app. It is the code
      # the --wait path already uses for a boot that never became
      # healthy, so "the app is not up" stays one meaning — and it is a
      # different question from the one `yamine stop` answers with its
      # 0/2/3/4, which is about what a stop did.
      def supervise_tree(ctx, hostnames, named_pids, reporter: nil, json: false)
        loop do
          sleep 0.5
          dead = named_pids.find { |pid, _| !ProxyControl.pid_alive?(pid) }
          next unless dead

          pid, name = dead
          status = ProcessTree.status(pid)
          log = app_log_path
          $stderr.puts "\n[#{name}] exited (pid #{pid}, #{describe_status(status)}) " \
            "— stopping the whole tree."
          reporter&.note("#{name} exited; cleaning up routes")
          if json
            # stdout stays the machine stream: the event lines above it,
            # this payload last, exactly as the --wait failure reads.
            puts JSON.generate({ ok: false, error: "child-exited", name: name,
              pid: pid, status: status&.exitstatus, signal: status&.termsig,
              log_path: File.file?(log) ? log : nil,
              log_tail: log_tail(log) }.compact)
          elsif File.file?(log)
            $stderr.puts log_tail(log, lines: 10)
            $stderr.puts "  log: #{log}"
          end
          cleanup_routes(ctx, hostnames)
          # Kill remaining children — by group, so a `sh -c` backend's
          # process dies with the shell we hold a pid for.
          named_pids.each_key do |other|
            ProcessTree.term(other)
          end
          exit 1
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
            # The children are in their own process groups, so the
            # terminal's signal reaches only us — this is the one place
            # their trees get told to stop. By group, not by pid: a
            # `sh -c` backend's real process is behind the pid we hold.
            pids.each { |pid| ProcessTree.term(pid) }
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
              # Group, not pid: the sidecar names the `sh -c` shell, and
              # the app behind it is the process that must stop.
              ProcessTree.term(pid)
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
          $stderr.puts "  Human: run this once in a terminal — yamine setup (or: sudo yamine service install)"
          $stderr.puts "  Agent/CI: the 443 service is installed by a human once per machine — it cannot be provisioned passwordlessly."
          $stderr.puts "    Steady-state hosts sync works via the grant instead:"
          $stderr.puts "      yamine sudoers > /tmp/yamine.sudoers"
          $stderr.puts "      sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine"
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

# frozen_string_literal: true

module Ask
  module Local
    class CLI
      # Boot commands: `ask-local`, `ask-local start`, `ask-local run`.
      # The config file is mandatory — missing file prints the fix and exits.
      # `boot_all` fans out over every process declared in config/local.yml.
      # No inference, no Procfile at boot, no single-process default.
      module BootCommand
        PORT_IGNORING = %w[jekyll middleman bridgetown].freeze

        module_function

        # Bare `ask-local` / `ask-local start` / `ask-local run`.
        # Reads config/local.yml via the resolver, ensures the proxy,
        # boots every process, supervises the tree, cleans up on exit.
        def run_inferred(ctx, args)
          variant = ENV["ASK_LOCAL_VARIANT"]
          opts = ctx.parse_flags(args, %i[variant tld force])
          resolved = resolve!(ctx, variant: opts[:variant] || variant, tld: opts[:tld])
          ensure_proxy!(ctx)
          boot_all(ctx, resolved, opts)
        end

        def run_explicit(ctx, args)
          run_inferred(ctx, args)
        end

        def run_named(ctx, name, _args)
          $stderr.puts "Error: `ask-local #{name}` is no longer supported."
          $stderr.puts "  All processes come from config/local.yml. Run `ask-local init` to create one."
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

          puts "ask-local (#{service})"
          puts "--"

          processes.each do |proc_name, entry|
            next if entry["proxy"] == false

            hostname = Resolver.hostname_for(resolved, proc_name)
            next unless hostname

            url = Hostname.url(hostname, port: ctx.proxy_port, tls: ctx.proxy_tls)
            hostnames = [hostname]
            puts "  [#{proc_name}] #{url}"

            # Each process cmd runs through the shell so $PORT (and other
            # env refs) expand — same trust boundary as a Procfile line
            # (repo code, not user input). Compound lines are refused.
            cmd = entry["cmd"].to_s
            if cmd.match?(Ask::Local::Procfile::COMPOUND)
              $stderr.puts "  [#{proc_name}] ERROR: compound line (&&, ||, |, ;) — run explicitly: ask-local run -- #{cmd}"
              next
            end

            port = opts[:app_port] || Ports.find_free
            shell_cmd = ["sh", "-c", cmd]
            # Always allow the proxied hostname in Rails dev (Rails ignores
            # this env var when not a Rails app — safe for every framework).
            app = runner.boot_run(name: proc_name, hostname: hostname, url: url,
              dir: Dir.pwd, command: shell_cmd, port: port, force: opts[:force],
              rails_dev_host: hostname)
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
          all_pids = routes_registered.map { |r| r[:app].pid }
          trap_cleanup(ctx, routes_registered.flat_map { |r| r[:hostnames] }, all_pids)
          supervise_tree(ctx, routes_registered.flat_map { |r| r[:hostnames] }, all_pids)
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
          path = ::Ask::Local::Procfile.find_file(Dir.pwd)
          return nil unless path
          lines = ::Ask::Local::Procfile.parse_file(path)
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
          Ask::Local::Resolver.resolve(Dir.pwd, variant: variant, tld: tld)
        end

        def ensure_proxy!(ctx)
          port = ctx.proxy_port
          tls = ctx.proxy_tls
          if ProxyControl.listening?(port)
            return if ProxyControl.ours?(port, tls: tls)
            $stderr.puts "Error: port #{port} is in use by another process."
            $stderr.puts "  Stop it, or ask-local proxy start -p <port>"
            exit 1
          end
          privileged = port < 1024 && !ProxyControl.root?
          if privileged && !ctx.interactive?
            $stderr.puts "Error: proxy is not running and port #{port} needs root."
            $stderr.puts "  Human: run this once — ask-local setup"
            $stderr.puts "  Agent/CI: pre-provision passwordless sudo once —"
            $stderr.puts "    ask-local sudoers > /tmp/ask-local.sudoers"
            $stderr.puts "    sudo install -o root -g wheel -m 440 /tmp/ask-local.sudoers /etc/sudoers.d/ask-local"
            $stderr.puts "  Or start the proxy by hand: sudo ask-local proxy start"
            exit 1
          end
          puts "Starting proxy#{privileged ? " (sudo)" : ""}..."
          begin
            Ask::Local::ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, sudo: privileged)
          rescue Ask::Local::ProxyNotRunningError => e
            $stderr.puts "Error: #{e.message.lines.first&.strip}"
            $stderr.puts "  Fix once: ask-local setup"
            exit 1
          end
        rescue Errno::EACCES
          $stderr.puts "Error: permission denied binding port #{port}."
          $stderr.puts "  Fix once: ask-local setup"
          exit 1
        end
      end
    end
  end
end

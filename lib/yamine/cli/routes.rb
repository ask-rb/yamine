# frozen_string_literal: true

module Yamine
  class CLI
    # Route and app-lifecycle commands: get/alias/list/prune,
    # stop/restart/log/status/open.
    module RoutesCommand
      module_function

      # yamine get <name> [--service x] [--variant y] [--tld z]
      #
      # Variant and TLDs are inherited from the CURRENT directory's
      # context (worktree branch, YAMINE_* env, config) so cross-service
      # wiring works inside a variant: from a fix-ui worktree,
      # `get backend` -> https://fix-ui.backend.localhost.
      def get(ctx, args)
        name = args.first
        raise Error, "Usage: yamine get <name> [--service s] [--variant v] [--tld t]" unless name

        opts = ctx.parse_flags(args[1..] || [], %i[service variant tld])
        context = Resolver.resolve(Dir.pwd, variant: opts[:variant])
        hostnames = Hostname.build(
          app: Sanitize.hostname_label(name),
          tlds: Array(context.tld || Yamine::Hostname::DEFAULT_TLD),
          variant: context.variant
        )
        puts Hostname.url(hostnames.first, port: ctx.proxy_port, tls: ctx.proxy_tls)
      end

      def list(ctx, args)
        json = args.delete("--json")
        routes = ctx.store.load_routes
        port = ctx.proxy_port
        tls = ctx.proxy_tls
        entries = routes.map do |r|
          { hostname: r["hostname"],
            url: Hostname.url(r["hostname"], port: port, tls: tls),
            target: r["target"], kind: r["kind"],
            pid: r["pid"], supervised: !r["spec"].nil?,
            alive: alive_state(ctx, r) }
        end
        if json
          require "json"
          puts JSON.generate({ routes: entries, proxy_port: port, tls: tls })
          return
        end
        if entries.empty?
          puts "No active routes."
          puts "Start an app with: yamine"
          return
        end
        puts "\nActive routes:\n"
        entries.each do |e|
          puts "  #{e[:url]}  ->  #{e[:target]}  #{label_for(e)}"
        end
        puts
      end

      def alive_state(ctx, route)
        if route["pid"] == 0
          ctx.backend_alive?(route) ? "reachable" : "unreachable"
        elsif ProxyControl.pid_alive?(route["pid"])
          "running"
        else
          "owner-gone"
        end
      rescue StandardError
        "unknown"
      end

      def label_for(entry)
        if entry[:pid] == 0
          "(alias, #{entry[:alive]})"
        else
          "(pid #{entry[:pid]}, #{entry[:alive]})"
        end
      end

      # Backend liveness per route: agents can see at a glance whether
      # the route points at something alive. Static aliases (pid 0)
      # report the probe, not a process.
      def route_label(ctx, route)
        entry = { pid: route["pid"], alive: alive_state(ctx, route) }
        label_for(entry)
      end

      def prune(ctx, _args)
        stale = ctx.store.prune_stale
        if stale.empty?
          puts "No stale routes."
        else
          stale.each { |r| puts "Removed stale route #{r["hostname"]}" }
        end
      end

      def alias_add(ctx, args)
        if args.first == "--remove"
          name = args[1] or raise Error, "Usage: yamine alias --remove <name>"
          hostname = alias_hostname(name)
          ctx.store.remove_route(hostname)
          puts "Removed alias #{hostname}."
          return
        end
        name, port_or_url = args
        raise Error, "Usage: yamine alias <name> <port|url>" unless name && port_or_url

        hostname = alias_hostname(name)
        target = port_or_url.match?(/\A\d+\z/) ? "127.0.0.1:#{port_or_url}" : port_or_url
        force = args.include?("--force")
        ctx.store.add_route(hostname, target, 0, kind: "tcp", force: force)
        puts "#{hostname} -> #{target}"
      end

      # A name containing dots is treated as a full hostname (any TLD);
      # otherwise it is a label under the current TLD context
      # (YAMINE_TLD first entry, else localhost).
      def alias_hostname(name)
        return Hostname.strip_port(name.downcase) if name.include?(".")

        tld = ENV["YAMINE_TLD"]&.split(",")&.map(&:strip)&.reject(&:empty?)&.first
        "#{Sanitize.hostname_label(name)}.#{tld || Hostname::DEFAULT_TLD}"
      end

      # Stop the app in the current directory (route + backend).
      # Exit codes are machine-readable for agents: 0 stopped something,
      # 2 no route here, 3 route existed but the backend was already gone.
      def stop(ctx, _args, out: $stdout)
        resolved = Resolver.resolve(Dir.pwd)
        hostnames = Resolver.hostnames(resolved)
        stopped = []
        gone = []
        hostnames.each do |hostname|
          entry = ctx.store.find(hostname)
          next unless entry

          backend_pid = ctx.backend_pid_for(entry)
          if backend_pid && ProxyControl.pid_alive?(backend_pid)
            begin
              Process.kill("TERM", backend_pid)
              if ctx.wait_for_exit(backend_pid, timeout: 10)
                stopped << "#{hostname} (backend #{backend_pid})"
              else
                stopped << "#{hostname} (backend #{backend_pid} still draining)"
              end
            rescue SystemCallError
              gone << hostname
            end
          else
            gone << hostname
          end
          ctx.store.remove_route(hostname)
          FileUtils.rm_f(File.join(ctx.store.dir, "backend-#{hostname}.pid"))
        end
        if stopped.any?
          stopped.each { |s| out.puts "Stopped #{s}." }
          return 0
        end
        if gone.any?
          out.puts "Route existed but the backend was already gone: #{gone.join(", ")}."
          return 3
        end

        out.puts "No yamine app running here."
        2
      end

      # Touch tmp/restart.txt so a supervised managed app reboots.
      def restart(_ctx, _args)
        path = File.join(Dir.pwd, "tmp", "restart.txt")
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.touch(path)
        puts "Touched #{path} — managed app restarts on next request."
      end

      # Tail the app log (default 50 lines); --follow streams.
      def log(ctx, args)
        follow = args.delete("--follow") || args.delete("-f")
        lines = (args.first || 50).to_i
        resolved = Resolver.resolve(Dir.pwd)
        path = File.expand_path(File.join(Dir.pwd, "log", "yamine-#{resolved.app}.log"))
        unless File.file?(path)
          puts "No log at #{path} yet."
          return
        end
        if follow
          exec("tail", "-F", "-n", lines.to_s, path)
        else
          puts File.readlines(path).last(lines).join
        end
      end

      # Print the effective naming context for this directory: what
      # `yamine` would boot here and why. Answers "why did I get
      # this URL" without booting anything. --json emits stable keys
      # for agents instead of prose.
      def status(_ctx, args)
        json = args.delete("--json")
        resolved = Resolver.resolve(Dir.pwd)
        hostnames = Resolver.hostnames(resolved)
        urls = hostnames.map do |h|
          Hostname.url(h, port: ProxyControl.default_port(true), tls: true)
        end
        payload = {
          app: resolved.app, app_source: resolved.sources[:app],
          tld: resolved.tld, tld_source: resolved.sources[:tld],
          host: resolved.host, host_source: resolved.sources[:host],
          variant: resolved.variant, variant_source: resolved.sources[:variant],
          urls: urls,
          processes: resolved.processes.keys,
          framework: Framework.detect(Dir.pwd).to_s
        }
        if json
          require "json"
          puts JSON.generate(payload)
          return
        end
        puts "app:       #{payload[:app]} (from #{payload[:app_source]})"
        if payload[:host]
          puts "host:      #{payload[:host]} (from #{payload[:host_source]})"
        else
          puts "tld:       #{payload[:tld]} (from #{payload[:tld_source]})"
        end
        puts "variant:   #{payload[:variant] || "(none)"} (from #{payload[:variant_source] || "no overlay file, flag, or env"})"
        puts "processes: #{payload[:processes].join(", ")}"
        puts "urls:"
        urls.each { |u| puts "  #{u}" }
        puts "framework: #{payload[:framework]}"
      end

      # Open the app URL in the default browser (macOS `open`).
      def open(ctx, args)
        name = args.first
        url =
          if name
            opts = ctx.parse_flags(args[1..] || [], %i[service variant tld])
            context = Resolver.resolve(Dir.pwd, variant: opts[:variant], tld: opts[:tld])
            hostnames = Hostname.build(app: Sanitize.hostname_label(name),
              tlds: Array(context.tld || Yamine::Hostname::DEFAULT_TLD),
              variant: context.variant)
            Hostname.url(hostnames.first, port: ctx.proxy_port, tls: ctx.proxy_tls)
          else
            resolved = Resolver.resolve(Dir.pwd)
            Hostname.url(Resolver.hostnames(resolved).first,
              port: ctx.proxy_port, tls: ctx.proxy_tls)
          end
        case RUBY_PLATFORM
        when /darwin/ then exec("open", url)
        when /linux/ then exec("xdg-open", url)
        else puts url
        end
      end
    end
  end
end

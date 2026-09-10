# frozen_string_literal: true

module Yamine
  class CLI
    # System commands: proxy, service, hosts, trust, clean, doctor, kamal.
    module SystemCommand
      # The launchd label: the service's identity, and what `launchctl
      # enable/kickstart/bootout` address it by. Renamed from "dev.ask.local"
      # (an ask-local leftover); the old label is cleared on install so the
      # two never coexist and fight over port 443.
      LAUNCHD_LABEL = "dev.yamine"
      LEGACY_LAUNCHD_LABELS = %w[dev.ask.local].freeze

      module_function

      def doctor(ctx, args)
        json = args.delete("--json")
        failed = Doctor.print(Doctor.run(store: ctx.store), out: $stdout, json: !!json)
        exit(failed.zero? ? 0 : 1)
      end

      def trust(_ctx, _args)
        result = Trust.trust
        if result[:trusted]
          puts "CA trusted."
        else
          $stderr.puts "Error: #{result[:error]}"
          exit 1
        end
      end

      def clean(ctx, _args)
        ProxyControl.stop(ctx.store)
        result = Trust.untrust
        puts "CA removed from trust store." if result[:removed]
        warn "CA untrust failed: #{result[:error]}" if result[:error]
        Hosts.clean
        require "fileutils"
        FileUtils.rm_rf(ctx.store.dir)
        puts "Cleaned yamine state."
      end

      def hosts(ctx, args)
        sub = args.first
        case sub
        when "sync"
          hostnames = ctx.store.load_routes.map { |r| r["hostname"] }
          if Hosts.sync(hostnames)
            puts "Synced #{hostnames.length} hostname(s) to /etc/hosts."
          elsif !ProxyControl.root? && !hostnames.empty?
            # /etc/hosts is root-owned; once the root service is
            # installed the guidance is "run yamine hosts sync" — so
            # make that command work by re-running it elevated.
            puts "Writing /etc/hosts needs root — re-running elevated..."
            state = Certs.state_dir
            cmd = ["env", "YAMINE_STATE_DIR=#{state}", RbConfig.ruby,
              ProxyControl.bin_path, "hosts", "sync"]
            exit(elevate(cmd) ? 0 : 1)
          else
            $stderr.puts "Could not write /etc/hosts (try sudo)."
            exit 1
          end
        when "clean"
          Hosts.clean
          puts "Removed yamine entries from /etc/hosts."
        else
          raise Error, "Usage: yamine hosts [sync|clean]"
        end
      end

      def proxy(ctx, args)
        sub = args.first
        case sub
        when "start"
          port, tls, foreground = parse_proxy_start(args[1..])
          tlds = active_tlds(args[1..])
          if foreground
            write_tls_marker(ctx, tls)
            write_tlds_file(ctx, tlds)
            # Record BEFORE serving. This process (the launchd/systemd
            # service, or a hand-run foreground proxy) IS the proxy, and
            # every reader trusts these files: doctor, Context's URL
            # building, the supervisor, `proxy stop`. Not recording left
            # the previous proxy's port on disk, so a machine serving
            # clean 443 still advertised :8443 everywhere.
            ProxyControl.write_proxy_state(ctx.store,
              pid: Process.pid, port: port, tls: tls)
            sup = Supervisor.new(store: ctx.store, runner: Runner.new(store: ctx.store),
              on_event: ->(m) { warn m })
            sup.start
            Proxy.new(store: ctx.store, port: port, tls: tls,
              state_dir: ctx.store.dir, supervisor: sup, tlds: tlds).start_foreground
          else
            ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, tlds: tlds)
            puts "Proxy started on port #{port}#{tls ? " (HTTPS)" : " (HTTP)"}."
          end
        when "stop"
          case ProxyControl.stop(ctx.store)
          when :stopped then puts "Proxy stopped."
          when :stale then puts "Removed stale proxy state."
          when :not_running then puts "Proxy is not running."
          when :unknown_process then puts "Port in use by an unknown process."
          when :needs_root
            # A root service keeps serving; say so rather than implying
            # success. Uninstalling is the real answer — signalling it
            # would just leave launchd's KeepAlive restarting it.
            $stderr.puts "The proxy runs as root (the launchd/systemd service)."
            $stderr.puts "  Uninstall it: sudo yamine service uninstall"
            exit 1
          end
        else
          raise Error, "Usage: yamine proxy [start|stop]"
        end
      end

      def write_tls_marker(ctx, tls)
        ctx.store.ensure_dir
        path = File.join(ctx.store.dir, "proxy.tls")
        tls ? File.write(path, "1") : File.write(path, "0")
      end

      # TLDs the proxy serves: --tld flags, else YAMINE_TLD, else
      # localhost. Persisted so auto-restarted daemons agree, and so
      # the 404 page knows which hosts are "ours" (rebinding boundary).
      def active_tlds(args)
        flags = []
        i = 0
        while i < args.length
          if args[i] == "--tld"
            flags << args.fetch(i + 1).to_s
            i += 2
          else
            i += 1
          end
        end
        list = flags.any? ? flags : (ENV["YAMINE_TLD"]&.split(",")&.map(&:strip) || [])
        list = list.reject(&:empty?).map(&:downcase).uniq
        list.empty? ? [Hostname::DEFAULT_TLD] : list
      end

      def write_tlds_file(ctx, tlds)
        ctx.store.ensure_dir
        File.write(File.join(ctx.store.dir, "proxy.tlds"), "#{tlds.join("\n")}\n")
      rescue SystemCallError
        nil
      end

      def parse_proxy_start(args)
        port = nil
        tls = true
        foreground = false
        i = 0
        while i < args.length
          case args[i]
          when "-p", "--port" then port = args.fetch(i + 1).to_i; i += 2
          when "--no-tls" then tls = false; i += 1
          when "--https" then tls = true; i += 1
          when "--foreground" then foreground = true; i += 1
          when "--tld" then i += 2 # consumed by active_tlds
          else i += 1
          end
        end
        [port || ProxyControl.default_port(tls), tls, foreground]
      end

      def service(ctx, args)
        sub = args.first
        case sub
        when "install" then exit(service_install(ctx, args) ? 0 : 1)
        when "uninstall" then exit(service_uninstall(ctx) ? 0 : 1)
        when "status" then service_status(ctx)
        else raise Error, "Usage: yamine service [install|uninstall|status]"
        end
      end

      # Print the scoped passwordless-sudo rules that let `service install`
      # (and only it) run without a prompt. The service re-execs the whole
      # gem under sudo, so the safe NOPASSWD grants exactly the gem path +
      # subcommand for the current user — never a bare interpreter. This is
      # how agents and repeat machines get clean :443 without a TTY.
      #
      #   macOS: sudo install -o root -g wheel -m 440 <(yamine sudoers) /etc/sudoers.d/yamine
      #   Linux: sudo install -o root -g root -m 440 <(yamine sudoers) /etc/sudoers.d/yamine
      def sudoers(_ctx, _args)
        require "etc"
        ruby = RbConfig.ruby
        bin = ProxyControl.bin_path
        user = ENV.fetch("USER", Etc.getlogin)
        puts <<~SUDOERS
          # yamine: let #{user} install/run the privileged proxy on port 443
          # without a password prompt. Scoped to yamine's own service
          # re-exec — the gem path above, not a bare interpreter.
          #{user} ALL=(root) NOPASSWD: #{ruby} #{bin} service install --internal
          #{user} ALL=(root) NOPASSWD: #{ruby} #{bin} service uninstall --internal
        SUDOERS
      end

      # Root-owned LaunchDaemon binding 80/443 at boot (puma-dev model).
      # Non-root runs re-exec under sudo once (--internal marks the root
      # half); the proxy runs with the invoking user's state dir so
      # routes registered by unprivileged CLIs are shared. The root half
      # can also write /etc/hosts.
      #
      # Non-interactive runs (agents, CI) use `sudo -n`: never prompts,
      # succeeds only when the scoped NOPASSWD grant from `yamine
      # sudoers` is installed, and fails fast with guidance otherwise.
      # Interactive runs use plain sudo (one password, then the service
      # is installed for good).
      #
      # Returns true when the service is installed. No exit here: the
      # bare `service install` CLI exits in `service`, while `setup`
      # keeps going (hosts sync, doctor) after a successful install.
      def service_install(ctx, args)
        if ProxyControl.root?
          install_service!(ctx)
        elsif args.include?("--internal")
          raise Error, "`service install --internal` is the root half of the sudo re-exec — run `yamine service install`"
        else
          puts "Installing system service (sudo required)..."
          state = Certs.state_dir
          cmd = ["env", "YAMINE_STATE_DIR=#{state}",
            RbConfig.ruby, ProxyControl.bin_path,
            "service", "install", "--internal"]
          elevate(cmd)
        end
      end

      def install_service!(ctx)
        case RUBY_PLATFORM
        when /darwin/ then install_launchd(ctx)
        when /linux/ then install_systemd
        else raise Error, "Service install not supported on #{RUBY_PLATFORM}"
        end
        # Root can write /etc/hosts, so sync the routes registered so
        # far while elevated — Safari works the moment setup finishes
        # (Chrome resolves *.localhost natively).
        sync_hosts_from_routes(ctx)
        true
      end

      def sync_hosts_from_routes(ctx)
        hostnames = ctx.store.load_routes.map { |r| r["hostname"] }
        if hostnames.empty?
          puts "    No routes registered yet — hosts sync will happen on the next boot."
        elsif Yamine::Hosts.synced?(hostnames)
          puts "    /etc/hosts already lists #{hostnames.length} hostname(s)."
        elsif Yamine::Hosts.sync(hostnames)
          puts "    Synced #{hostnames.length} hostname(s) to /etc/hosts."
        else
          warn "    could not write /etc/hosts (run `sudo yamine hosts sync` later)"
        end
      end

      # Run a privileged command via sudo. Interactive: plain sudo (one
      # prompt). Non-interactive: `sudo -n` — no prompt ever; requires the
      # NOPASSWD grant from `yamine sudoers`. On failure prints the
      # provisioning hint so agents/CI know exactly what to install.
      def elevate(cmd)
        interactive = $stdin.tty? && ENV["CI"].nil?
        sudo_args = interactive ? ["sudo"] : ["sudo", "-n"]
        ok = Command.run(*sudo_args, *cmd)
        return true if ok

        # An interactive sudo failure is auth or the elevated command
        # itself (whose error is already on screen) — re-run and read it.
        # The scoped-grant hint only helps passwordless non-interactive
        # runs, where a missing NOPASSWD rule is the usual cause.
        if interactive
          $stderr.puts "sudo failed — re-run `yamine setup` to try again."
        else
          $stderr.puts "sudo failed — install the scoped grant once:"
          $stderr.puts "  yamine sudoers > /tmp/yamine.sudoers"
          $stderr.puts "  sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine"
        end
        false
      end

      def user_home_for_service
        sudo_user = ENV["SUDO_USER"]
        if sudo_user && !sudo_user.empty?
          require "etc"
          Etc.getpwnam(sudo_user).dir
        else
          Certs.home
        end
      rescue ArgumentError
        Certs.home
      end

      def install_launchd(ctx)
        require "etc"
        home = user_home_for_service
        state_dir = ENV["YAMINE_STATE_DIR"] || File.join(home, ".yamine")
        dir = "/Library/LaunchDaemons"
        FileUtils.mkdir_p(dir)
        plist = <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>Label</key><string>#{LAUNCHD_LABEL}</string>
            <key>ProgramArguments</key>
            <array>
              <string>#{RbConfig.ruby}</string>
              <string>#{ProxyControl.bin_path}</string>
              <string>proxy</string><string>start</string><string>--foreground</string>
              <string>--port</string><string>#{ProxyControl::DEFAULT_TLS_PORT}</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
              <key>YAMINE_STATE_DIR</key><string>#{state_dir}</string>
              <key>HOME</key><string>#{home}</string>
            </dict>
            <key>KeepAlive</key><true/>
            <key>RunAtLoad</key><true/>
          </dict>
          </plist>
        PLIST
        remove_legacy_launchd(dir)
        path = File.join(dir, "#{LAUNCHD_LABEL}.plist")
        File.write(path, plist)
        File.chmod(0o644, path)
        # launchd requires /Library/LaunchDaemons plists to be
        # root-owned; we are root here (sudo re-exec). Enforce it
        # explicitly: File.write keeps an existing file's owner, so a
        # stale user-owned plist from an older version would otherwise
        # survive the overwrite and bootstrap fails with error 5.
        # Trust the CA into the System keychain while elevated: silent
        # (no GUI popup) and trusted for every user on the machine.
        File.chown(0, 0, path) if Process.uid.zero?
        ensure_system_ca_trust
        puts "    Registering the launchd service on port 443..."
        launchctl_bootstrap(path)
        puts "Installed root LaunchDaemon on port 443 (state: #{state_dir})."
      end

      # True when the trust store covers the CA this machine should be
      # serving with — regenerating the CA first if it is missing,
      # expiring, or renamed.
      #
      # The ordering is the whole point, so it lives in one place rather
      # than at each call site. `trusted?` compares a marker against the
      # fingerprint of the certificate ON DISK, and a proxy regenerates
      # the CA at boot when the name changes. Checking the marker before
      # the CA is current therefore reads a stale match, skips trust, and
      # lets the proxy come up serving a CA the keychain does not trust —
      # breaking TLS for every route.
      def ca_current_and_trusted?(dir = Certs.state_dir)
        Certs.ensure_ca(dir)
        Certs.trusted?(dir)
      end

      # Root-only CA trust: the System keychain (all users, no prompt).
      # Safe to call repeatedly — once the marker is set it is a no-op.
      # Prints before doing work: the System keychain add can take a few
      # seconds, and this runs in the root half of setup where silence
      # reads as a hang.
      def ensure_system_ca_trust
        return if ca_current_and_trusted?(Certs.state_dir)

        puts "    Trusting the CA into the System keychain..."
        result = Trust.trust
        warn "    CA trust warning: #{result[:error]}" unless result[:trusted]
      end

      # Modern launchctl system-domain verbs. The legacy `launchctl load`
      # is rejected by current macOS with error 5 (Input/output error) —
      # and worse, it can print that error while still exiting 0, so the
      # old code "succeeded" without the service actually running.
      # bootstrap/bootout are the supported verbs (same as puma-dev and
      # portless); extracted so the command sequence is unit-testable.
      def launchctl_bootstrap(path)
        # Best-effort: booting out a service that was never loaded prints
        # "Boot-out failed: 5" — nothing to clear then, so keep it quiet.
        # Any real leftover is removed silently; bootstrap errors below
        # stay loud.
        Command.run("launchctl", "bootout", "system", path, out: File::NULL, err: File::NULL)
        unless Command.run("launchctl", "bootstrap", "system", path)
          raise Error, "launchctl bootstrap failed — check the plist at #{path}"
        end
        Command.run("launchctl", "enable", "system/#{LAUNCHD_LABEL}")
        Command.run("launchctl", "kickstart", "-k", "system/#{LAUNCHD_LABEL}")
      end

      def launchctl_bootout(path)
        Command.run("launchctl", "bootout", "system", path)
      end

      # The launchd label, and the pre-rename one that must be cleared.
      # A label is the service's identity: installing the new one while
      # the old plist is still loaded would leave TWO root proxies
      # fighting over port 443 (whichever booted last wins, and the loser
      # crash-loops under KeepAlive).
      #
      # Boot out and delete any plist from a previous label. Idempotent:
      # bootout on a service that was never loaded prints an error and
      # exits non-zero, which is expected and quiet.
      def remove_legacy_launchd(dir = "/Library/LaunchDaemons")
        LEGACY_LAUNCHD_LABELS.each do |label|
          path = File.join(dir, "#{label}.plist")
          next unless File.file?(path)

          Command.run("launchctl", "bootout", "system", path, out: File::NULL, err: File::NULL)
          FileUtils.rm_f(path)
          puts "    Removed legacy launchd service #{label}."
        end
      end

      # Pure unit-file builder (testable without root). Binds 80/443 at
      # boot; the proxy runs with the invoking user's state dir.
      def systemd_unit
        home = user_home_for_service
        state_dir = ENV["YAMINE_STATE_DIR"] || File.join(home, ".yamine")
        <<~UNIT
          # /etc/systemd/system/yamine.service  (binds 80/443 at boot)
          [Unit]
          After=network.target

          [Service]
          ExecStart=#{RbConfig.ruby} #{ProxyControl.bin_path} proxy start --foreground --port #{ProxyControl::DEFAULT_TLS_PORT}
          Environment=YAMINE_STATE_DIR=#{state_dir}
          Environment=HOME=#{home}

          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      # Install + start the systemd unit (mirrors portless). We are root
      # here (sudo re-exec). The unit is written root-owned, then enabled
      # and started.
      def install_systemd
        unit_path = "/etc/systemd/system/yamine.service"
        File.write(unit_path, systemd_unit)
        File.chmod(0o644, unit_path)
        File.chown(0, 0, unit_path) if Process.uid.zero?
        puts "    Registering the systemd service on port 443..."
        Command.run("systemctl", "daemon-reload") or raise Error, "systemctl daemon-reload failed"
        Command.run("systemctl", "enable", "--now", "yamine") or raise Error, "systemctl enable failed"
        puts "Installed systemd service yamine on port 443."
      end

      def service_uninstall(ctx)
        if !ProxyControl.root?
          puts "Removing system service (sudo required)..."
          state = Certs.state_dir
          cmd = ["env", "YAMINE_STATE_DIR=#{state}",
            RbConfig.ruby, ProxyControl.bin_path, "service", "uninstall", "--internal"]
          return elevate(cmd)
        end
        case RUBY_PLATFORM
        when /darwin/
          path = "/Library/LaunchDaemons/#{LAUNCHD_LABEL}.plist"
          launchctl_bootout(path) if File.file?(path)
          FileUtils.rm_f(path)
          # Also clear any pre-rename service, so uninstall leaves no root
          # proxy behind on a machine upgraded from an older yamine.
          remove_legacy_launchd
          puts "Removed root LaunchDaemon."
        when /linux/
          Command.run("systemctl", "disable", "--now", "yamine")
          Command.run("systemctl", "daemon-reload")
          FileUtils.rm_f("/etc/systemd/system/yamine.service")
          puts "Removed systemd service yamine."
        else
          raise Error, "Service uninstall not supported on #{RUBY_PLATFORM}"
        end
        true
      end

      def service_status(ctx)
        port = ProxyControl.proxy_port(ctx.store)
        if port.nil? || !ProxyControl.listening?(port)
          puts "Proxy not running."
        elsif ProxyControl.ours?(port, tls: ProxyControl.proxy_tls(ctx.store))
          puts "Proxy running on port #{port}."
        else
          puts "Port #{port} in use by another process."
        end
      end


      def init(ctx, _args)
        config_path = File.join(Dir.pwd, Config::RELATIVE_PATH)
        if File.file?(config_path)
          $stderr.puts "config/local.yml already exists at #{config_path}"
          return
        end
        FileUtils.mkdir_p(File.join(Dir.pwd, Config::RELATIVE_DIR))

        # Migrate Procfile.dev / Procfile if present.
        procfile = Yamine::Procfile.find_file(Dir.pwd)
        service = Yamine::Sanitize.hostname_label(File.basename(Dir.pwd))

        process_lines = []
        if procfile
          lines = Yamine::Procfile.parse_file(procfile)
          lines.each do |l|
            type = Yamine::Procfile.classify(l.name) == :background ? "false" : "true"
            process_lines << "    #{l.name}:"
            process_lines << "      cmd: #{l.command}"
            process_lines << "      proxy: #{type}"
            process_lines << "      # NOTE: compound line - run explicitly" if l.compound
          end
        else
          # Default: a single web process. Detect Rails (Gemfile with
          # rails) vs plain Rack (config.ru) and pick the right boot.
          has_rails = File.file?(File.join(Dir.pwd, "Gemfile")) &&
            File.read(File.join(Dir.pwd, "Gemfile")).match?(/gem ["']rails["']/)
          cmd =
            if has_rails
              "bundle exec puma -b tcp://127.0.0.1:$PORT config.ru"
            elsif File.file?(File.join(Dir.pwd, "config.ru"))
              "puma -b tcp://127.0.0.1:$PORT config.ru"
            else
              "bin/rails server -p $PORT"
            end
          process_lines << "    web:"
          process_lines << "      cmd: #{cmd}"
          process_lines << "      proxy: true"
        end

        content = <<~YAML
          # config/local.yml — yamine configuration (Kamal-style).
          # This is the only source of truth. Run `yamine` to boot everything.
          # Overlay variants with config/local.<variant>.yml.

          service: #{service}

          proxy:
            tld: localhost

          processes:
        #{process_lines.join("\n")}

          env:
            clear:
              RAILS_ENV: development
        YAML
        File.write(config_path, content)
        puts "Created #{config_path}"
        puts "  service: #{service}"
        puts "  processes from: #{procfile || 'defaults'}"
        puts "Run `yamine start` to boot."
      end


      def setup(ctx, args)
        if args.include?("--help") || args.include?("-h")
          puts <<~HELP
            Usage: yamine setup [--no-service]

            One-shot workstation setup for clean https://<app>.localhost URLs:

              Default: install the root proxy service on 443 — runs under
              sudo ONCE, trusting the CA system-wide in the same step
              (no separate GUI authorization popup).
              --no-service: trust the CA at user level, then run a sudo
              daemon instead (no boot persistence; ephemeral machines).

            Both finish by syncing /etc/hosts and verifying with doctor.
          HELP
          return
        end

        puts "Note: setup takes a few seconds while the 443 service installs and starts."

        no_service = args.include?("--no-service")
        steps = no_service ? 4 : 3

        if no_service
          step("1/#{steps} Trusting local CA") do
            result = Yamine::Trust.trust
            unless result[:trusted]
              abort_setup("CA trust failed: #{result[:error]}",
                "Run `yamine trust` manually to see the underlying error,",
                "then re-run `yamine setup`.")
            end
          end
          step("2/#{steps} Starting proxy sudo daemon on port 443") do
            unless ensure_sudo_daemon(ctx)
              abort_setup("Could not start the proxy daemon on port 443.",
                "Check the log, then re-run `yamine setup`.")
            end
          end
        else
          step("1/#{steps} Installing proxy service on port 443 (trusts CA)") do
            # Runs under sudo once; inside, the CA is trusted into the
            # System keychain silently (no GUI popup) and the launchd
            # service is bootstrapped. One password entry, that's all.
            unless ensure_root_service(ctx)
              abort_setup("Could not install the proxy service.",
                "Fallback: `yamine setup --no-service` for a sudo daemon",
                "without boot persistence.")
            end
          end
        end

        step("#{no_service ? 3 : 2}/#{steps} Syncing /etc/hosts") do
          hostnames = ctx.store.load_routes.map { |r| r["hostname"] }
          next if hostnames.empty?

          # The root service install already synced under elevation; a
          # plain re-run must not fail rewriting /etc/hosts unprivileged
          # when the block is already in place.
          unless Yamine::Hosts.synced?(hostnames) || Yamine::Hosts.sync(hostnames)
            abort_setup("Could not write /etc/hosts.",
              "Run `sudo yamine hosts sync`, then re-run `yamine setup`.")
          end
        end

        step("#{no_service ? 4 : 3}/#{steps} Verifying with doctor") do
          failed = Doctor.print(Doctor.run(store: ctx.store), out: $stdout)
          if failed.zero?
            puts "\nSetup complete: https://<app>.localhost URLs are ready."
            puts "Try it: cd ~/code/myapp && yamine"
          else
            abort_setup("Doctor reports #{failed} failing check(s) (see above).",
              "Fix the reported issues, then re-run `yamine setup`.")
          end
        end
      end

      def step(label)
        puts "\n==> #{label}..."
        yield
        puts "    ok"
      end

      def abort_setup(problem, *fixes)
        $stderr.puts "\nSetup failed: #{problem}"
        fixes.each { |f| $stderr.puts "  #{f}" }
        exit 1
      end

      # The two ways to get a privileged proxy on 443: a human runs setup
      # once (interactive sudo), or an agent/CI image is pre-provisioned
      # with the scoped NOPASSWD rules from `yamine sudoers`.
      def privileged_port_hint
        [
          "Human: run this once — yamine setup",
          "Agent/CI: pre-provision passwordless sudo once —",
          "  yamine sudoers > /tmp/yamine.sudoers",
          "  sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine"
        ]
      end

      # Install the root service (boot-persistent). Returns true when a
      # proxy is up on 443 afterwards, false otherwise. Never falls back
      # to a high port silently: a :port suffix in URLs would corrupt the
      # stable-URL promise, so failure here is a hard error with guidance.
      def ensure_root_service(ctx)
        return false unless service_install(ctx, [])
        wait_for_ours(ctx, 443, tls: true)
      rescue Error, SystemCallError => e
        warn "    service install failed: #{e.message}"
        false
      end

      # Sudo daemon for 443 without boot persistence (--no-service).
      def ensure_sudo_daemon(ctx)
        port, tls = 443, true
        unless ctx.interactive?
          warn "    no TTY available for the sudo prompt."
          warn "    Agent/CI: pre-provision passwordless sudo once —"
          warn "      yamine sudoers > /tmp/yamine.sudoers"
          warn "      sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine"
          return false
        end
        ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, sudo: true)
        wait_for_ours(ctx, port, tls: tls)
      rescue Yamine::ProxyNotRunningError, SystemCallError => e
        warn "    daemon start failed: #{e.message.lines.first&.strip}"
        false
      end

      # Poll until our proxy answers on the port. The freshly installed
      # service takes a few seconds to boot, so show motion instead of a
      # frozen prompt: a spinner on a terminal, dots elsewhere. Silent
      # when the proxy is already up.
      def wait_for_ours(ctx, port, tls:, timeout: 20)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        terminal = $stdout.respond_to?(:tty?) && $stdout.tty?
        waiting = false
        frame = 0
        ok = false
        loop do
          if ProxyControl.ours?(port, tls: tls)
            ok = true
            break
          end
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          unless waiting
            print terminal ? "    starting the proxy on port #{port} " : "    (starting the proxy on port #{port}"
            waiting = true
          end
          if terminal
            print %w[| / - \\][frame % 4], "\b"
          else
            print "."
          end
          $stdout.flush
          frame += 1
          sleep 0.5
        end
        if waiting
          if terminal
            puts(ok ? "\r    proxy is up on port #{port}." : "\r    still not up on port #{port}.")
          else
            puts ")"
          end
        end
        ok
      end

      # yamine start — one-setup-and-go: idempotent workstation setup
      # (trust, 443, hosts) when doctor fails, then boots the app in the
      # current directory. The single command you run day-to-day; existing
      # bare `yamine` keeps working via BootCommand.run_inferred, and
      # `setup` stays for explicit re-setup.
      def start(ctx, args)
        if args.include?("--help") || args.include?("-h")
          puts <<~HELP
            Usage: yamine start [options]

            One-setup-and-go: if the workstation isn't ready (CA, proxy,
            hosts), runs the minimal needed setup first, then boots the
            app in the current directory.

              yamine start              # block until every route is healthy, then supervise
              yamine start --no-wait   # fire-and-forget (register routes immediately)
              yamine start --json       # machine-readable result payload (--wait only)
              yamine start -- --help   # pass --help to the app, not here

            Options are passed through to the boot path:
              --variant <v> --tld <tld> --force --app-port <port>
              --wait (alias, default) --no-wait --json

            Default waits: every process is spawned concurrently, each
            healthcheck (or TCP accept when none is declared) is polled,
            routes are registered only when all are healthy, and `ready:`
            is printed with exit 0. On failure everything spawned is
            killed, the failed process + its log tail is printed, and
            the CLI exits 1 — no half-booted routes. `--no-wait` keeps
            the old fire-and-forget path.

            Setup failures become hard errors pointing at `yamine setup`;
            non-interactive CI without a running proxy exits immediately.
          HELP
          return
        end

        # Fast path: every doctor check passes => skip setup entirely.
        # This makes `start` as fast as `yamine` on a ready machine.
        if needs_workstation_setup?(ctx)
          ensure_workstation!(ctx)
        end
        BootCommand.run_inferred(ctx, args)
      end

      def needs_workstation_setup?(ctx)
        Yamine::Doctor.run(store: ctx.store).any? { |c| !c.ok }
      end


      # Quiet workstation setup for `start`: trust the CA, ensure a proxy
      # on this run's port (443 by default — root service, sudo daemon
      # fallback), and sync hosts. Each step is idempotent; only missing
      # pieces run. Non-interactive CI without a proxy fails fast rather
      # than prompting for sudo.
      #
      # The port comes from ctx, not a literal: YAMINE_PORT is the
      # documented escape hatch for CI and sandboxes ("where 443 is
      # impossible"), and hardcoding 443 here demanded root for a port
      # those users had already chosen to avoid.
      def ensure_workstation!(ctx)
        # 1. CA
        unless ca_current_and_trusted?(ctx.store.dir)
          result = Yamine::Trust.trust
          unless result[:trusted]
            abort_setup("CA trust failed: #{result[:error]}",
              "Run `yamine setup` in a terminal (handles trust + service),",
              "then re-run `yamine start`.")
          end
        end

        # 2. Proxy on the port this run wants
        port = ctx.proxy_port
        tls = ctx.proxy_tls
        unless Yamine::ProxyControl.listening?(port) && ProxyControl.ours?(port, tls: tls)
          privileged = port < 1024
          if privileged && !Yamine::ProxyControl.root? && !ctx.interactive?
            abort_setup("Proxy is not running and port #{port} needs root to bind.", *privileged_port_hint)
          end
          ok =
            if ProxyControl.root?
              Yamine::CLI::SystemCommand.ensure_root_service(ctx)
            elsif ctx.interactive?
              begin
                Yamine::ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, sudo: privileged)
                wait_for_ours(ctx, port, tls: tls)
              rescue Yamine::ProxyNotRunningError, SystemCallError => e
                warn "    daemon start failed: #{e.message.lines.first&.strip}"
                false
              end
            elsif !privileged
              # Non-interactive but unprivileged: nothing to elevate, so
              # start the daemon directly instead of failing.
              begin
                Yamine::ProxyControl.spawn_daemon(store: ctx.store, port: port, tls: tls, sudo: false)
                wait_for_ours(ctx, port, tls: tls)
              rescue Yamine::ProxyNotRunningError, SystemCallError => e
                warn "    daemon start failed: #{e.message.lines.first&.strip}"
                false
              end
            else
              false
            end
          unless ok
            abort_setup("Proxy is not running and could not be started on port #{port}.",
              *privileged_port_hint)
          end
        end

        # 3. Hosts (best-effort: only needed for Safari and custom TLDs —
        # Chrome/Firefox/Edge resolve *.localhost natively). Already-synced
        # is the common case and must stay silent: warning there sent
        # people to a sudo write for a file that needed nothing.
        hostnames = ctx.store.load_routes.map { |r| r["hostname"] }
        unless hostnames.empty? || Yamine::Hosts.synced?(hostnames) || Hosts.sync(hostnames)
          warn "Warning: could not write /etc/hosts (try sudo yamine hosts sync)."
        end
      end
      # yamine kamal <variant> [--app myapp] [--domain preview.example.com]
      def kamal(_ctx, args)
        opts = {}
        rest = []
        i = 0
        a = args.dup
        while i < a.length
          case a[i]
          when "--app" then opts[:app] = a.fetch(i + 1); i += 2
          when "--domain" then opts[:domain] = a.fetch(i + 1); i += 2
          when "--tld" then opts[:tld] = a.fetch(i + 1); i += 2
          else rest << a[i]; i += 1
          end
        end
        variant = rest.first
        raise Error, "Usage: yamine kamal <variant> [--app myapp] [--domain preview.example.com] [--tld <tld>]" unless variant
        tld = opts[:tld] || ENV["YAMINE_TLD"]&.split(",")&.first || "localhost"

        app = opts[:app] || Resolver.resolve(Dir.pwd).app
        domain = opts[:domain] || ENV["YAMINE_KAMAL_DOMAIN"] || "preview.example.com"
        slug = Sanitize.hostname_label(variant)
        puts "# Paste into deploy.yml proxy section for a preview of variant #{slug}:"
        puts "proxy:"
        puts "  ssl: true"
        puts "  hosts:"
        puts "    - #{app}-#{slug}.#{domain}"
        puts "  # Prefer Kamal multi-host for production; single-host preview above is fine for ephemeral branches."
      end

      # Per-worktree databases: list/create/drop, plus orphan cleanup.
      # `db list` shows every claimed database with its worktree dir.
      # `db create` resolves this worktree's name and creates it.
      # `db drop <name>` drops one database (refuses without --force
      # when its worktree still exists).
      def db(ctx, args)
        sub = args.first
        case sub
        when "list", nil then db_list(ctx)
        when "create" then db_create(ctx)
        when "drop" then db_drop(ctx, args[1..] || [])
        else raise Error, "Usage: yamine db [list|create|drop <name> [--force]]"
        end
      end

      def db_list(ctx)
        map = Database.load_map(ctx.store.dir)
        if map.empty?
          puts "No worktree databases claimed yet."
          puts "Boot an app with a DATABASE_URL template to create one."
          return
        end
        map.each do |name, info|
          alive = File.directory?(info["dir"]) ? "" : " (worktree gone)"
          puts "  #{name}  ->  #{info["dir"]}#{alive}"
        end
      end

      def db_create(ctx)
        resolved = Resolver.resolve(Dir.pwd)
        name = Database.name_for(Dir.pwd, env: boot_env_name,
          state_dir: ctx.store.dir)
        template = ENV["DATABASE_URL"]
        unless template && !template.strip.empty?
          $stderr.puts "Error: set DATABASE_URL (template with host/user; database segment is replaced)."
          exit 1
        end
        if Database.ensure_exists(name, template)
          puts "Database #{name} ready."
        else
          $stderr.puts "Error: could not create #{name}. Check the database server is running."
          exit 1
        end
      end

      def db_drop(ctx, args)
        force = args.delete("--force")
        name = args.first
        raise Error, "Usage: yamine db drop <name> [--force]" unless name

        map = Database.load_map(ctx.store.dir)
        info = map[name]
        if info && File.directory?(info["dir"]) && !force
          $stderr.puts "Error: worktree #{info["dir"]} still exists. Use --force to drop #{name} anyway."
          exit 1
        end
        if drop_database(ctx, name)
          map.delete(name)
          Database.save_map(ctx.store.dir, map)
          puts "Dropped #{name}."
        else
          $stderr.puts "Error: could not drop #{name}."
          exit 1
        end
      end

      def drop_database(_ctx, name)
        template = ENV["DATABASE_URL"]
        return false unless template && !template.strip.empty?

        case Database.adapter_for(template)
        when :postgres
          uri = URI.parse(template)
          _out, status = Open3.capture2("dropdb", name, env: Database.pg_env(uri))
          status.success?
        when :mysql
          uri = URI.parse(template)
          args = ["-h", uri.host || "127.0.0.1", "-u",
                  URI.decode_www_form_component(uri.user || "root")]
          _out, status = Open3.capture2("mysqladmin", *args, "drop", name, "-f")
          status.success?
        else
          false
        end
      rescue SystemCallError
        false
      end

      def boot_env_name
        ENV.fetch("RAILS_ENV", "development")
      end

      # Worktree helpers: list claimed databases with liveness, clean
      # drops databases whose worktree dirs are gone.
      def worktree(ctx, args)
        sub = args.first
        case sub
        when "list", nil
          map = Database.load_map(ctx.store.dir)
          if map.empty?
            puts "No worktree databases claimed yet."
            return
          end
          map.each do |name, info|
            alive = File.directory?(info["dir"]) ? "alive" : "gone"
            puts "  #{name}  #{info["dir"]}  (#{alive})"
          end
        when "clean"
          orphaned = Database.orphaned(ctx.store.dir)
          if orphaned.empty?
            puts "No orphaned worktree databases."
            return
          end
          orphaned.each do |name, _info|
            if drop_database(ctx, name)
              puts "Dropped orphaned #{name}."
            else
              $stderr.puts "Could not drop #{name} — remove manually."
            end
          end
          map = Database.load_map(ctx.store.dir)
          orphaned.each_key { |name| map.delete(name) }
          Database.save_map(ctx.store.dir, map)
        else
          raise Error, "Usage: yamine worktree [list|clean]"
        end
      end
    end
  end
end

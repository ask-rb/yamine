# frozen_string_literal: true

require "optparse"

module Yamine
  # Command-line interface. Thin dispatcher: every command lives in
  # lib/yamine/cli/{boot,routes,system}.rb behind a shared Context.
  # OptionParser only, no Thor.
  #
  # In non-interactive environments (no TTY or CI=1) we fail early with
  # a clear message instead of prompting (portless lesson).
  class CLI
    SUBCOMMANDS = %w[run get alias hosts list doctor trust clean prune proxy service sudoers kamal stop restart log status open setup start init].freeze

    def self.run(argv)
      new.run(argv)
      0
    rescue Error => e
      $stderr.puts "Error: #{e.message}"
      1
    rescue OptionParser::InvalidOption => e
      $stderr.puts "Error: #{e.message}"
      1
    end

    def run(argv)
      args = argv.dup
      if args.empty? || (!SUBCOMMANDS.include?(args.first) && !args.first.start_with?("-"))
        return BootCommand.run_inferred(Context.new, args)
      end

      cmd = args.shift
      ctx = Context.new
      case cmd
      when "run" then BootCommand.run_explicit(ctx, args)
      when "get" then RoutesCommand.get(ctx, args)
      when "alias" then RoutesCommand.alias_add(ctx, args)
      when "hosts" then SystemCommand.hosts(ctx, args)
      when "list" then RoutesCommand.list(ctx, args)
      when "doctor" then SystemCommand.doctor(ctx, args)
      when "trust" then SystemCommand.trust(ctx, args)
      when "clean" then SystemCommand.clean(ctx, args)
      when "prune" then RoutesCommand.prune(ctx, args)
      when "proxy" then SystemCommand.proxy(ctx, args)
      when "service" then SystemCommand.service(ctx, args)
      when "sudoers" then SystemCommand.sudoers(ctx, args)
      when "setup" then SystemCommand.setup(ctx, args)
      when "init" then SystemCommand.init(ctx, args)
      when "start" then SystemCommand.start(ctx, args)
      when "kamal" then SystemCommand.kamal(ctx, args)
      when "stop"
        exit RoutesCommand.stop(ctx, args)
      when "restart" then RoutesCommand.restart(ctx, args)
      when "log" then RoutesCommand.log(ctx, args)
      when "status" then RoutesCommand.status(ctx, args)
      when "open" then RoutesCommand.open(ctx, args)
      when "--help", "-h" then help
      when "--version", "-v" then puts "yamine #{VERSION}"
      else BootCommand.run_named(ctx, cmd, args)
      end
    end

    private

    def help
      puts <<~HELP
        yamine - Stable named .localhost URLs for Ruby development.

        Usage:
          yamine start [name] [cmd...]  One-setup-and-go: setup if needed, then boot -> https://<app>.localhost
          yamine setup                One-shot workstation setup without booting (run once)
          yamine                        Bare form of `start` -> https://<app>.localhost
          yamine run [cmd]              Same, with explicit command
          yamine <name> <cmd>           Run with explicit name
          yamine get <name>             Print URL for a service
          yamine alias <name> <port>    Static route (e.g. Docker)
          yamine list                   Show active routes (+ backend liveness)
          yamine status                 Show effective naming context here
          yamine open [name]            Open the app URL in a browser
          yamine doctor                 Check proxy, routes, DNS, CA trust
          yamine trust                  Add local CA to trust store
          yamine clean                  Remove state and hosts entries
          yamine prune                  Remove stale routes
          yamine proxy start|stop       Control the proxy
          yamine service install|status|uninstall   OS startup service
          yamine sudoers                Print scoped passwordless-sudo rules for port 443
          yamine hosts sync|clean       Manage /etc/hosts entries
          yamine kamal <variant>        Preview-deploy snippet for Kamal
          yamine stop                   Stop this app's backend + routes
          yamine restart                Touch tmp/restart.txt
          yamine log [-f] [n]           Tail (or follow) this app's backend log

        Flags: --name, --service, --variant, --tld, --branch, --force,
               --app-port, --proc (pick a Procfile process, e.g. --proc web)
        Env: YAMINE_NAME/SERVICE/VARIANT/TLD/PORT/STATE_DIR, YAMINE_BRANCH=1
      HELP
    end

    # Backwards-compatible access for tests written against the old
    # monolith: CLI.new.send(:inject_port_flags / :procfile_command).
    def inject_port_flags(command, port)
      BootCommand.inject_port_flags(command, port)
    end
    def procfile_command(process = nil)
      BootCommand.procfile_command(process)
    end
  end
end

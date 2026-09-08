# frozen_string_literal: true

module Yamine
  class CLI
    # Shared state and helpers for command objects. Every command gets a
    # Context instead of reaching into CLI privates, so cli.rb stays a
    # thin dispatcher.
    class Context
      def store
        @store ||= RouteStore.new(Certs.state_dir,
          on_warning: ->(m) { warn m })
      end

      def interactive?
        $stdin.tty? && ENV["CI"].nil?
      end

      def proxy_port
        ProxyControl.proxy_port(store) || ProxyControl.default_port(proxy_tls)
      end

      def proxy_tls
        ProxyControl.proxy_tls(store)
      end

      def report_unresolved(hostnames)
        missing = Hosts.unresolved(hostnames)
        return if missing.empty?

        warn "Warning: #{missing.join(", ")} will not resolve. Run: yamine hosts sync"
      end

      def wait_for_exit(pid, timeout:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          return true unless ProxyControl.pid_alive?(pid)

          sleep 0.25
        end
        !ProxyControl.pid_alive?(pid)
      end

      def backend_pid_for(entry)
        return nil unless entry

        sidecar = File.join(store.dir, "backend-#{entry["hostname"]}.pid")
        return nil unless File.file?(sidecar)

        pid = File.read(sidecar).strip.to_i
        pid.positive? ? pid : nil
      rescue SystemCallError, ArgumentError
        nil
      end

      def backend_alive?(entry)
        case entry["kind"]
        when "socket"
          File.socket?(entry["target"].to_s)
        when "tcp"
          host, port = entry["target"].to_s.split(":", 2)
          begin
            TCPSocket.new(host, port.to_i).close
            true
          rescue SystemCallError
            false
          end
        else
          false
        end
      end

      def parse_flags(args, known)
        opts = { rest: [] }
        i = 0
        rest_start = nil
        while i < args.length
          arg = args[i]
          if arg == "--"
            rest_start = i + 1
            break
          elsif arg.start_with?("--")
            key = arg.sub(/\A--/, "").tr("-", "_").to_sym
            if known.include?(key)
              if %i[branch force].include?(key)
                opts[key] = true
                i += 1
              else
                opts[key] = args.fetch(i + 1)
                i += 2
              end
            else
              raise Error, "Unknown flag #{arg}"
            end
          else
            rest_start = i
            break
          end
        end
        opts[:rest] = rest_start ? args[rest_start..] : []
        opts
      end
    end
  end
end

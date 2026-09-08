# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"

module Yamine
  # Boots and supervises one app backend.
  #
  # Managed Ruby apps (Rails/Rack with puma available): puma bound to a
  # unix socket — zero TCP ports, readiness by dialing the socket
  # (puma-dev model). Without puma, managed degrades to rackup on TCP
  # (run-mode shape). Run mode (everything else): subprocess with
  # injected PORT/YAMINE_URL, readiness by TCP connect.
  class Runner
    SOCKET_DIR = File.join("tmp", "sockets")
    SOCKET_NAME = "yamine.sock"

    App = Struct.new(:name, :hostname, :url, :pid, :target, :kind,
      :command, keyword_init: true)

    def initialize(store:, on_log: nil)
      @store = store
      @on_log = on_log || ->(msg) { puts msg }
    end

    # Boot a managed Rack app. Socket when puma exists, else TCP rackup.
    def boot_managed(name:, hostname:, url:, dir:, force: false)
      if puma_available?(dir)
        boot_socket(name: name, hostname: hostname, url: url, dir: dir, force: force)
      else
        boot_tcp_fallback(name: name, hostname: hostname, url: url, dir: dir, force: force)
      end
    end

    # Boot a backend for an existing route (daemon supervisor). Does not
    # re-register the route — target path is deterministic
    # (dir/tmp/sockets/yamine.sock) and the route entry stays.
    def boot_supervised(name:, hostname:, url:, dir:)
      socket_path = File.expand_path(File.join(dir, SOCKET_DIR, SOCKET_NAME))
      FileUtils.mkdir_p(File.dirname(socket_path))
      FileUtils.rm_f(socket_path)
      pid = spawn_socket(dir, socket_path, name, url)
      unless wait_for_socket(socket_path, timeout: 60)
        stop_pid(pid)
        raise Error, "App '#{name}' did not boot within 60s. " \
          "Last log lines (#{log_path(dir, name)}):\n#{log_tail(log_path(dir, name))}"
      end
      write_backend_pid(hostname, pid)
      App.new(name: name, hostname: hostname, url: url, pid: pid,
        target: socket_path, kind: "socket", command: nil)
    end

    def boot_socket(name:, hostname:, url:, dir:, force: false)
      socket_path = File.expand_path(File.join(dir, SOCKET_DIR, SOCKET_NAME))
      FileUtils.mkdir_p(File.dirname(socket_path))
      FileUtils.rm_f(socket_path)
      pid = spawn_socket(dir, socket_path, name, url)

      unless wait_for_socket(socket_path, timeout: 60)
        stop_pid(pid)
        raise Error, "App '#{name}' did not boot within 60s. " \
          "Last log lines (#{log_path(dir, name)}):\n#{log_tail(log_path(dir, name))}"
      end

      @store.add_route(hostname, socket_path, Process.pid, kind: "socket",
        force: force, spec: { "dir" => dir })
      write_backend_pid(hostname, pid)
      App.new(name: name, hostname: hostname, url: url, pid: pid,
        target: socket_path, kind: "socket", command: socket_command(dir, socket_path))
    end

    def boot_tcp_fallback(name:, hostname:, url:, dir:, force: false)
      port = Ports.find_free
      env = child_env(dir, url: url, port: port)
      config_ru = File.join(dir, "config.ru")
      cmd = ["rackup", "-o", "127.0.0.1", "-p", port.to_s, config_ru]
      pid = with_clean_env { spawn(env, *cmd, chdir: dir, out: log_path(dir, name), err: [:child, :out]) }
      Process.detach(pid)
      unless wait_for_tcp(port, timeout: 60)
        stop_pid(pid)
        raise Error, "App '#{name}' did not boot within 60s. " \
          "Last log lines (#{log_path(dir, name)}):\n#{log_tail(log_path(dir, name))}"
      end
      target = "127.0.0.1:#{port}"
      @store.add_route(hostname, target, Process.pid, kind: "tcp", force: force)
      write_backend_pid(hostname, pid)
      App.new(name: name, hostname: hostname, url: url, pid: pid,
        target: target, kind: "tcp", command: cmd)
    end

    # Run an arbitrary command with PORT + YAMINE_URL. Returns App.
    # register: false spawns without a route (background processes).
    def boot_run(name:, hostname:, url:, dir:, command:, port: nil, force: false,
      rails_dev_host: nil, register: true)
      port ||= Ports.find_free
      env = child_env(dir, url: url, port: port, rails_dev_host: rails_dev_host)
      pid = with_clean_env { spawn(env, *command, chdir: dir) }
      Process.detach(pid)
      target = "127.0.0.1:#{port}"
      if register
        @store.add_route(hostname, target, Process.pid, kind: "tcp", force: force)
        write_backend_pid(hostname, pid)
      end
      App.new(name: name, hostname: hostname, url: url, pid: pid,
        target: target, kind: "tcp", command: command)
    end

    def child_env(dir, url:, port:, rails_dev_host: nil)
      env = { "YAMINE_URL" => url }
      env["PORT"] = port.to_s if port
      env["HOST"] = "127.0.0.1"
      ca = File.join(Certs.state_dir, "ca.pem")
      env["NODE_EXTRA_CA_CERTS"] = ca if File.file?(ca)
      # Rails blocks unknown Host headers in development. Allow the
      # proxied hostname so Rails apps boot behind yamine with zero
      # config — this replaces the yamine-rails hosts patch.
      env["RAILS_DEVELOPMENT_HOSTS"] = rails_dev_host if rails_dev_host
      env
    end

    def puma_available?(dir)
      with_clean_env { bundle_puma?(dir) || system_puma? }
    end

    # Spawned backends must not inherit our own bundle: under
    # `bundle exec` rubygems restricts executables to the Gemfile,
    # hiding system puma/rackup from the child. Strip Bundler env so
    # the app boots with its own gems.
    def with_clean_env(&block)
      if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
        Bundler.with_unbundled_env(&block)
      else
        saved = {}
        %w[BUNDLE_GEMFILE RUBYOPT RUBYLIB GEM_HOME GEM_PATH].each do |k|
          saved[k] = ENV.delete(k)
        end
        begin
          yield
        ensure
          saved.each { |k, v| ENV[k] = v unless v.nil? }
        end
      end
    end

    private

    def socket_command(dir, socket_path)
      socket = "unix://#{socket_path}"
      config_ru = File.join(dir, "config.ru")
      # Puma 8 takes config.ru positionally (no --rackup flag).
      if bundle_puma?(dir)
        ["bundle", "exec", "puma", "-b", socket, config_ru]
      else
        ["puma", "-b", socket, config_ru]
      end
    end

    # Shared spawn for CLI boots and daemon supervision.
    def spawn_socket(dir, socket_path, name, url)
      env = child_env(dir, url: url, port: nil)
      cmd = socket_command(dir, socket_path)
      pid = with_clean_env { spawn(env, *cmd, chdir: dir, out: log_path(dir, name), err: [:child, :out]) }
      Process.detach(pid)
      pid
    end

    def bundle_puma?(dir)
      gemfile = File.join(dir, "Gemfile")
      return false unless File.file?(gemfile)

      out, status = Open3.capture2("bundle", "exec", "puma", "-V",
        chdir: dir, err: File::NULL)
      status.success? && !out.empty?
    rescue SystemCallError
      false
    end

    def system_puma?
      _out, status = Open3.capture2("puma", "-V", err: File::NULL)
      status.success?
    rescue SystemCallError
      false
    end

    def wait_for_socket(path, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.socket?(path)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.25
      end
      begin
        UNIXSocket.new(path).close
        true
      rescue SystemCallError
        false
      end
    end

    def wait_for_tcp(port, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        begin
          TCPSocket.new("127.0.0.1", port).close
          return true
        rescue SystemCallError
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.25
        end
      end
    end

    def log_path(dir, name)
      path = File.expand_path(File.join(dir, "log", "yamine-#{name}.log"))
      FileUtils.mkdir_p(File.dirname(path))
      Log.rotate(path)
      path
    end

    # Sidecar so `yamine stop` can find the backend after the CLI
    # that booted it has exited (the route owner pid is the CLI, not
    # the backend). Removed alongside the route on clean stop.
    def write_backend_pid(hostname, pid)
      @store.ensure_dir
      File.write(File.join(@store.dir, "backend-#{hostname}.pid"), "#{pid}\n")
    rescue SystemCallError
      nil
    end

    def log_tail(path, lines: 10)
      return "(no log file)" unless File.file?(path)

      File.readlines(path).last(lines).join
    rescue SystemCallError
      "(unreadable log)"
    end

    def stop_pid(pid)
      Process.kill("TERM", pid)
    rescue SystemCallError
      nil
    end
  end
end

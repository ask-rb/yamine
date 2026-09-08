# frozen_string_literal: true

require "fileutils"
require "json"

module Yamine
    # Persistent hostname -> backend mapping in ~/.yamine/routes.json.
    #
    # Entries: {hostname, target, kind, pid, agent} where target is a unix
    # socket path (kind "socket") or "127.0.0.1:PORT" (kind "tcp"), pid 0
    # marks a static alias, and agent names the owner (YAMINE_AGENT or
    # USER@HOST fallback) so concurrent agents can coexist. Guarded by
    # flock; stale PIDs pruned on read.
    # Modeled on portless RouteStore and puma-dev's AppPool registry.
  class RouteStore
    FILE_MODE = 0o644
    DIR_MODE = 0o755

    attr_reader :dir, :routes_path, :pid_path, :port_path

    def initialize(dir, on_warning: nil)
      @dir = dir
      @routes_path = File.join(dir, "routes.json")
      @pid_path = File.join(dir, "proxy.pid")
      @port_path = File.join(dir, "proxy.port")
      @on_warning = on_warning
    end

    def ensure_dir
      FileUtils.mkdir_p(dir, mode: DIR_MODE)
      File.chmod(DIR_MODE, dir)
      Ownership.fix(dir)
    rescue SystemCallError
      nil
    end

    def with_lock
      ensure_dir
      File.open("#{routes_path}.lock", File::CREAT | File::RDWR, FILE_MODE) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    def load_routes(prune: false)
      return [] unless File.file?(routes_path)

      parsed = JSON.parse(File.read(routes_path))
      unless parsed.is_a?(Array)
        @on_warning&.call("Corrupted routes file (expected array): #{routes_path}")
        return []
      end
      routes = parsed.select { |r| valid_route?(r) }
      alive = routes.select { |r| r["pid"] == 0 || alive?(r["pid"]) }
      save_routes(alive) if prune && alive.length != routes.length
      alive
    rescue JSON::ParserError
      @on_warning&.call("Corrupted routes file (invalid JSON): #{routes_path}")
      []
    rescue SystemCallError
      []
    end

    def load_routes_raw
      return [] unless File.file?(routes_path)

      parsed = JSON.parse(File.read(routes_path))
      parsed.is_a?(Array) ? parsed.select { |r| valid_route?(r) } : []
    rescue JSON::ParserError, SystemCallError
      []
    end

    # Returns killed pid when force takes over a live route.
    # `spec` marks daemon-supervised managed apps ({dir: ...}); the
    # proxy supervisor may idle-kill and boot-on-request those backends.
    # `agent` records the owner (defaults to Agent.name); foreign-owned
    # live routes can only be taken with force: true, and the conflict
    # error names the other agent plus its worktree dir.
    def add_route(hostname, target, pid, kind:, force: false, spec: nil, agent: nil)
      agent ||= Agent.name
      killed = nil
      with_lock do
        routes = load_routes(prune: true)
        enforce_quota!(routes, agent, hostname)
        existing = routes.find { |r| r["hostname"] == hostname }
        if existing && existing["pid"] != pid && alive?(existing["pid"])
          unless force
            raise RouteConflictError.new(hostname, existing["pid"],
              existing_agent: existing["agent"],
              existing_dir: existing.dig("spec", "dir"))
          end

          begin
            Process.kill("TERM", existing["pid"])
            killed = existing["pid"]
          rescue SystemCallError
            nil
          end
        end
        routes.reject! { |r| r["hostname"] == hostname }
        entry = { "hostname" => hostname, "target" => target, "kind" => kind,
                  "pid" => pid, "agent" => agent }
        entry["spec"] = spec if spec
        routes << entry
        save_routes(routes)
      end
      killed
    end

    # Live routes owned by one agent (for quotas, targeted prune/stop).
    def routes_for(agent)
      load_routes.select { |r| r["agent"] == agent }
    end

    # Remove stale entries belonging to one agent only; other agents'
    # routes are untouched even when their owners are dead.
    def prune_stale(agent: nil)
      stale = []
      with_lock do
        all = load_routes_raw
        alive, dead = all.partition { |r| r["pid"] == 0 || alive?(r["pid"]) }
        stale = agent ? dead.select { |r| r["agent"] == agent } : dead
        save_routes(alive + (dead - stale)) unless stale.empty?
      end
      stale
    end

    def remove_route(hostname, owner_pid: nil)
      with_lock do
        routes = load_routes(prune: true)
        routes.reject! do |r|
          r["hostname"] == hostname && (owner_pid.nil? || r["pid"] == owner_pid)
        end
        save_routes(routes)
      end
    end

    def find(hostname)
      load_routes.find { |r| r["hostname"] == hostname }
    end

    private

    # Per-agent route cap. Counts the agent's live routes (excluding the
    # hostname being (re)registered, so restarts never trip the quota).
    # Limit 0 disables the cap. Raises QuotaExceededError naming the
    # agent, the count, and the fix.
    def enforce_quota!(routes, agent, hostname)
      limit = Agent.max_routes
      return if limit.zero?

      count = routes.count { |r| r["agent"] == agent && r["hostname"] != hostname }
      raise QuotaExceededError.new(agent, limit, count) if count >= limit
    end

    def valid_route?(value)
      value.is_a?(Hash) &&
        value["hostname"].is_a?(String) &&
        value["target"].is_a?(String) &&
        value["pid"].is_a?(Integer) &&
        (value["spec"].nil? || (value["spec"].is_a?(Hash) && value["spec"]["dir"].is_a?(String)))
    end

    def save_routes(routes)
      File.write(routes_path, JSON.pretty_generate(routes))
      File.chmod(FILE_MODE, routes_path)
      Ownership.fix(routes_path)
    rescue SystemCallError
      nil
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue SystemCallError
      false
    end
  end
end

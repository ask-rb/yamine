# frozen_string_literal: true

module Yamine
  class Error < StandardError; end
  class ConfigError < Error; end
  class RouteConflictError < Error
    attr_reader :hostname, :existing_pid, :existing_agent, :existing_dir

    def initialize(hostname, existing_pid, existing_agent: nil, existing_dir: nil)
      @hostname = hostname
      @existing_pid = existing_pid
      @existing_agent = existing_agent
      @existing_dir = existing_dir
      owner = if existing_agent && !existing_agent.empty?
                "agent #{existing_agent.inspect}#{existing_dir ? " (#{existing_dir})" : ""}"
              else
                "PID #{existing_pid}"
              end
      super("\"#{hostname}\" is already registered by a running #{owner}. " \
            "Use --force to override.")
    end
  end
  class QuotaExceededError < Error
    attr_reader :agent, :limit, :count

    def initialize(agent, limit, count)
      @agent = agent
      @limit = limit
      @count = count
      super("Agent #{agent.inspect} already owns #{count} routes (limit #{limit}). " \
            "Stop something first: `yamine stop`, or prune one agent's orphans " \
            "with `yamine prune --agent NAME`.")
    end
  end
  class ProxyNotRunningError < Error; end
  class CertError < Error; end
end

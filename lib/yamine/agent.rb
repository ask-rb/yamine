# frozen_string_literal: true

module Yamine
  # Agent identity for multi-agent codebases.
  #
  # Every route records which agent booted it so concurrent agents can
  # coexist: list shows owners, conflicts name the other agent, quotas
  # are enforced per agent, and stop/prune can target one agent without
  # touching another's live backends. Identity comes from YAMINE_AGENT
  # (set by the harness per session); without it we fall back to
  # USER@HOST so humans sharing a machine still get distinct owners.
  module Agent
    module_function

    def name
      env = ENV["YAMINE_AGENT"]
      return env.strip unless env.nil? || env.strip.empty?

      user = ENV["USER"] || ENV["LOGNAME"] || "unknown"
      host = begin
        require "socket"
        Socket.gethostname
      rescue StandardError
        "localhost"
      end
      "#{user}@#{host}"
    end

    # Default per-agent route cap. Generous: N agents x M services must
    # fit in the ephemeral port range with headroom. Overridable via
    # YAMINE_MAX_ROUTES (0 disables the cap).
    DEFAULT_MAX_ROUTES = 32

    def max_routes
      raw = ENV["YAMINE_MAX_ROUTES"]
      return DEFAULT_MAX_ROUTES if raw.nil? || raw.strip.empty?

      Integer(raw)
    rescue ArgumentError
      DEFAULT_MAX_ROUTES
    end
  end
end

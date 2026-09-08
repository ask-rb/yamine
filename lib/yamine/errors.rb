# frozen_string_literal: true

module Yamine
  class Error < StandardError; end
  class ConfigError < Error; end
  class RouteConflictError < Error
    attr_reader :hostname, :existing_pid

    def initialize(hostname, existing_pid)
      @hostname = hostname
      @existing_pid = existing_pid
      super("\"#{hostname}\" is already registered by a running process " \
            "(PID #{existing_pid}). Use --force to override.")
    end
  end
  class ProxyNotRunningError < Error; end
  class CertError < Error; end
end

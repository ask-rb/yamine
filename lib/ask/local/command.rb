# frozen_string_literal: true

require "open3"

module Ask
  module Local
    # Injectable command runner for privileged/child-process work.
    #
    # Every system()/Open3 call that tests must control goes through here
    # (elevation re-exec, launchctl, systemctl, security). Unit tests stub
    # Command.run / Command.capture2 so they never shell out — no real
    # sudo prompt, no keychain mutation, hermetic and CI-safe. The real
    # implementations are the thin wrappers below.
    #
    # A plain class (not module_function): Mocha stubs class methods
    # reliably, whereas module_function singletons dodge the stub and the
    # real command would run.
    class Command
      # True when the command exited 0. Mirrors Kernel#system semantics.
      def self.run(*args)
        system(*args)
      end

      # [stdout, Process::Status] — mirrors Open3.capture2.
      def self.capture2(*args)
        Open3.capture2(*args)
      end
    end
  end
end

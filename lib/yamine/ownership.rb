# frozen_string_literal: true

require "etc"
require "fileutils"

module Yamine
  # File ownership across the root/user boundary.
  #
  # The sudo-spawned daemon and the root LaunchDaemon both write into
  # the invoking user's state dir. The first root-owned file lands,
  # the unprivileged CLI can no longer register routes — and the
  # failure looks like corruption, not permissions. Every root write
  # path calls fix() so the tree stays user-owned.
  module Ownership
    module_function

    # The user behind sudo, or nil when not elevated.
    def invoking_user
      sudo_user = ENV["SUDO_USER"]
      return nil if sudo_user.nil? || sudo_user.empty?

      Etc.getpwnam(sudo_user)
    rescue ArgumentError
      nil
    end

    # Chown path (recursively for dirs) to the invoking user. No-op
    # when not running as root or when the user cannot be resolved.
    def fix(*paths)
      user = invoking_user
      return unless user
      return unless Process.uid.zero?

      paths.each do |path|
        begin
          if File.directory?(path) && !File.symlink?(path)
            FileUtils.chown_R(user.uid, user.gid, path)
          else
            FileUtils.chown(user.uid, user.gid, path)
          end
        rescue SystemCallError, ArgumentError
          nil
        end
      end
    end

    # Fresh state files a root proxy creates: routes, pid/port/tls
    # markers and the log. Called after ensure_dir in daemon boot paths.
    def chown_state_dir(dir)
      fix(dir)
    end
  end
end

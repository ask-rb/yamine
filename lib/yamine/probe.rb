# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

module Yamine
  # What databases an app actually has — asked, never guessed.
  #
  # A Rails multi-database app keeps its per-database URLs wherever it
  # likes (credentials, ENV, hard-coded); yamine must not parse
  # database.yml or touch decryption keys to learn them. The app
  # itself answers: `bin/rails runner` prints the resolved
  # configuration for the environment, so whatever the app would
  # really connect to is exactly what yamine provisions, names, and
  # drops. Credentials decrypt inside that process — the probe never
  # sees a key.
  #
  # The runner emits one `YAMINE_DBS=<json>` line; Rails boot noise
  # shares stdout, so the marker (never the last line) finds the
  # payload. Any failure — no bin/rails, boot error, timeout — returns
  # nil: the caller falls back to the single-database path. A probe is
  # an enhancement, not a requirement, and it must never take a boot
  # down with it.
  module Probe
    module_function

    MARKER = "YAMINE_DBS="
    TIMEOUT = 90

    # Runs inside the app (bin/rails runner), so configuration_hash is
    # fully resolved: Rails has already parsed any `url:` into
    # components and decrypted credentials. The URL is rebuilt here
    # from those components — a password travels from credentials to
    # the claim file without yamine ever parsing config itself.
    # SQLite-family adapters keep their scheme and skip the host part;
    # relative paths already isolate per-worktree, so they never enter
    # the multi-database claim.
    SCRIPT = <<~'RUBY'
      require "json"
      require "uri"
      rows = ActiveRecord::Base.configurations
        .configs_for(env_name: ENV.fetch("RAILS_ENV", "development"))
        .map do |c|
          h = c.configuration_hash
          db = h[:database].to_s
          url = h[:url].to_s
          if url.empty?
            scheme = { "postgresql" => "postgres", "postgres" => "postgres",
                       "postgis" => "postgres", "mysql2" => "mysql",
                       "trilogy" => "mysql" }[h[:adapter].to_s]
            if scheme
              info = +""
              if h[:username]
                info << URI.encode_www_form_component(h[:username].to_s)
                if h[:password]
                  info << ":" << URI.encode_www_form_component(h[:password].to_s)
                end
                info << "@"
              end
              host = h[:host].to_s
              authority = host.empty? ? "#{info}" : "#{info}#{host}#{h[:port] ? ":#{h[:port]}" : ""}"
              url = "#{scheme}://#{authority}/#{db}"
            else
              url = "#{h[:adapter]}:#{db}"
            end
          end
          { "name" => c.name, "database" => db, "url" => url }
        end
      puts "YAMINE_DBS=#{JSON.generate(rows)}"
    RUBY

    # [{ "name", "database", "url" }, ...] for the environment, or nil
    # when the app cannot answer (not Rails, boot failure, timeout).
    def rails_databases(dir, env: nil)
      env ||= ENV.fetch("RAILS_ENV", "development")
      bin = File.join(dir, "bin", "rails")
      return nil unless File.file?(bin)

      out = +""
      status = nil
      # A stray DATABASE_URL (or NAME_DATABASE_URL) in the caller's
      # environment would win over database.yml inside the resolver —
      # the probe must see the app's own configuration. spawn MERGES
      # the env hash over the inherited one, so merely omitting the
      # keys would leave them in place: pass them as nil to unset.
      scrub = ENV.keys
        .select { |k| k == "DATABASE_URL" || k.end_with?("_DATABASE_URL") }
        .to_h { |k| [k, nil] }
      child_env = scrub.merge("RAILS_ENV" => env)
      Open3.popen2e(child_env, bin, "runner", SCRIPT, chdir: dir) do |stdin, stdout, wait|
        stdin.close
        begin
          Timeout.timeout(TIMEOUT) { out = stdout.read }
        rescue Timeout::Error
          Process.kill("KILL", wait.pid) rescue nil
          wait.value rescue nil
          return nil
        end
        status = wait.value
      end
      return nil unless status&.success?

      parse(out)
    rescue SystemCallError, IOError
      nil
    end

    # The marker line amidst whatever the boot printed. JSON parse
    # failure returns nil rather than raising: garbage in, "cannot
    # probe" out.
    def parse(output)
      line = output.to_s.lines.find { |l| l.start_with?(MARKER) }
      return nil unless line

      rows = JSON.parse(line.delete_prefix(MARKER).strip)
      return nil unless rows.is_a?(Array)

      rows.select { |r| r.is_a?(Hash) && r["name"] && r["url"] && r["database"] }
        .then { |r| r.empty? ? nil : r }
    rescue JSON::ParserError
      nil
    end

    # The subset that lives on a server (postgres/mysql). SQLite and
    # friends need no provisioning — their relative paths are already
    # per-worktree — so they never enter a claim.
    def server_backed(rows)
      rows.select { |r| %i[postgres mysql].include?(Yamine::Database.adapter_for(r["url"])) }
    end
  end
end

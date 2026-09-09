# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module Yamine
  # Per-worktree databases. Every worktree directory gets its own database
  # so concurrent agents never share tables: no migration races, no seed
  # pollution, no schema drift between branches.
  #
  # Naming: <sanitized-dir-basename>_<env> — e.g. /Users/kaka/code/myapp-fix
  # becomes myapp_fix_development. The branch a worktree has checked out is
  # irrelevant and mutable, so it plays no part; the directory is stable.
  # The main checkout keeps the bare <basename>_<env> name. Postgres
  # identifiers cap at 63 bytes; overlong names truncate with a hash
  # suffix (same rule as hostname labels).
  #
  # Collision guard: two directories can sanitize identically
  # (myapp-fix vs myapp_fix). A state file records which directory
  # claimed which name first; on collision the newcomer gets a short
  # hash suffix. Silent sharing would be exactly the bug this exists to
  # kill, so the check is mandatory, not best-effort.
  #
  # Framework-agnostic: yamine injects DATABASE_URL and never touches
  # framework files. SQLite needs nothing (relative paths already isolate
  # per worktree). Creation runs the app's own schema-load command from
  # config/local.yml — never assumed.
  module Database
    module_function

    MAX_IDENTIFIER_BYTES = 63
    STATE_FILE = "databases.json"

    # Database name for a worktree dir + env (development/test).
    # Main checkout (no worktree marker) keeps the bare name.
    def name_for(dir, env: "development", state_dir: nil)
      base = sanitize(File.basename(File.expand_path(dir)))
      name = "#{base}_#{env}"
      name = truncate(name)
      claimed = claim(name, dir, state_dir: state_dir)
      claimed || "#{truncate("#{base}_#{short_hash(dir)}")}_#{env}"
    end

    # The main checkout is the one whose .git is a directory (linked
    # worktrees have a .git FILE pointing into /worktrees/). Main keeps
    # the bare name; only linked worktrees get suffixed names... in
    # practice every dir gets the mapping, but main's mapping is itself.
    def main_checkout?(dir)
      File.directory?(File.join(File.expand_path(dir), ".git"))
    end

    def sanitize(name)
      name.downcase.gsub(/[^a-z0-9_]/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def truncate(name)
      return name if name.bytesize <= MAX_IDENTIFIER_BYTES

      hash = Digest::SHA256.hexdigest(name)[0, 6]
      prefix = name.byteslice(0, MAX_IDENTIFIER_BYTES - 7).gsub(/_+\z/, "")
      "#{prefix}_#{hash}"
    end

    def short_hash(dir)
      Digest::SHA256.hexdigest(File.expand_path(dir))[0, 6]
    end

    # Record dir -> name claim; returns the name if ours (or unclaimed),
    # nil if another dir claimed it first (caller must suffix).
    def claim(name, dir, state_dir: nil)
      return name unless state_dir

      dir = File.expand_path(dir)
      map = load_map(state_dir)
      if map.key?(name) && map[name]["dir"] != dir
        return nil
      end
      map[name] = { "dir" => dir, "claimed_at" => Time.now.utc.iso8601 }
      save_map(state_dir, map)
      name
    rescue SystemCallError
      name
    end

    def load_map(state_dir)
      path = File.join(state_dir, STATE_FILE)
      return {} unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def save_map(state_dir, map)
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, STATE_FILE), JSON.pretty_generate(map))
    rescue SystemCallError
      nil
    end

    # Databases whose worktree dirs no longer exist (for `worktree clean`).
    def orphaned(state_dir)
      load_map(state_dir).select { |_, v| !File.directory?(v["dir"]) }
    end

    # Adapter detection from DATABASE_URL scheme. Returns :postgres,
    # :mysql, :sqlite, or :unknown. Only postgres/mysql get create +
    # DATABASE_URL treatment; sqlite is left alone (relative paths
    # already isolate per worktree).
    def adapter_for(database_url)
      str = database_url.to_s.strip
      return :sqlite if str.empty?

      scheme = str[/\A[a-z0-9+]+/i].to_s.downcase
      case scheme
      when "postgres", "postgresql" then :postgres
      when "mysql", "mysql2" then :mysql
      when "sqlite", "sqlite3" then :sqlite
      else :unknown
      end
    end

    # Build a DATABASE_URL for name from a template URL (host, port, user
    # preserved; database segment replaced). Returns nil when the template
    # is absent or sqlite.
    def url_for(name, template_url)
      return nil if template_url.nil? || template_url.strip.empty?
      return nil if adapter_for(template_url) == :sqlite

      uri = URI.parse(template_url)
      uri.path = "/#{name}"
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    # True when the named database already exists. False covers both
    # missing and unreachable server — ensure_exists decides creation.
    def exists?(name, database_url)
      case adapter_for(database_url)
      when :postgres then pg_exists?(name, database_url)
      when :mysql then mysql_exists?(name, database_url)
      else false
      end
    end

    # Create the database if missing. Uses createdb/mysqladmin when
    # available; returns true/false, never raises (boot reports, not dies).
    def ensure_exists(name, database_url)
      case adapter_for(database_url)
      when :postgres then ensure_postgres(name, database_url)
      when :mysql then ensure_mysql(name, database_url)
      else false
      end
    end

    def ensure_postgres(name, database_url)
      uri = URI.parse(database_url)
      env = pg_env(uri)
      return true if pg_exists?(name, database_url)

      _out, status = Open3.capture2(env, "createdb", name)
      status.success?
    rescue SystemCallError
      false
    end

    def pg_exists?(name, database_url)
      uri = URI.parse(database_url)
      out, status = Open3.capture2(pg_env(uri), "psql", "-lqt")
      return false unless status.success?

      out.split("\n").any? do |line|
        line.split("|").first.to_s.strip == name
      end
    rescue SystemCallError
      false
    end

    def mysql_exists?(name, database_url)
      uri = URI.parse(database_url)
      args = mysql_args(uri)
      out, status = Open3.capture2("mysql", *args, "-e", "SHOW DATABASES;")
      status.success? && out.split("\n").include?(name)
    rescue SystemCallError
      false
    end

    def ensure_mysql(name, database_url)
      uri = URI.parse(database_url)
      args = mysql_args(uri)
      _out, status = Open3.capture2("mysqladmin", *args, "create", name)
      status.success? || mysql_exists?(name, database_url)
    rescue SystemCallError
      false
    end

    def mysql_args(uri)
      args = ["-h", uri.host || "127.0.0.1", "-P", (uri.port || 3306).to_s,
              "-u", URI.decode_www_form_component(uri.user || "root")]
      args += ["-p#{URI.decode_www_form_component(uri.password)}"] if uri.password
      args
    end

    def pg_env(uri)
      {
        "PGHOST" => uri.host || "127.0.0.1",
        "PGPORT" => (uri.port || 5432).to_s,
        "PGUSER" => URI.decode_www_form_component(uri.user || ENV["USER"].to_s),
        "PGPASSWORD" => uri.password ? URI.decode_www_form_component(uri.password) : nil
      }.compact
    end
  end
end

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
    # Written into a worktree at add time; the app's database.yml
    # reads it and suffixes every database URL, so hand-run commands
    # (console, test, db:migrate) land on the worktree's own
    # databases too — env injection only ever reaches processes
    # yamine spawns.
    MARKER_FILE = ".yamine-db-suffix"

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
      # Merge, don't replace: boot re-claims on every run, and a
      # multi-database claim's suffix/names/bases are stored under
      # this key — a fresh hash would erase them and orphan the whole
      # set on the next drop.
      map[name] = (map[name] || {}).merge("dir" => dir,
        "claimed_at" => Time.now.utc.iso8601)
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

    # Claim URLs carry database passwords (the app's own resolved
    # config, probed at worktree-add time), so the state file is
    # private — it held no secrets before multi-database claims.
    def save_map(state_dir, map)
      FileUtils.mkdir_p(state_dir)
      path = File.join(state_dir, STATE_FILE)
      File.write(path, JSON.pretty_generate(map))
      File.chmod(0o600, path)
    rescue SystemCallError
      nil
    end

    # ── multi-database claims ─────────────────────────────────────
    #
    # A multi-database claim carries the whole set beside the usual
    # dir/claimed_at:
    #   suffix  the token every database name gains — also the marker
    #           file's contents, the one string yamine and the app's
    #           database.yml must agree on, byte for byte
    #   names   config name -> actual database name
    #   bases   config name -> the app's own URL (server coordinates
    #           for create/drop; where the suffix gets inserted)
    # Single-database claims predate this and have none of the three;
    # every reader falls back to the claim key as the one name.

    # The suffix for a worktree: the claim key minus the env. Base
    # names already carry the environment (myrr_markdown_development),
    # so appending "_development" a second time only burns identifier
    # budget. The claim key keeps the env (and the collision guard);
    # the suffix is what has to fit inside a database name.
    def suffix_for(claim_name, env)
      stripped = claim_name.delete_suffix("_#{env}")
      stripped.empty? ? claim_name : stripped
    end

    # Fit the suffix so `base + "_" + suffix` stays within the
    # identifier cap for ANY base: budget against the longest one.
    # Fitting happens once, here, because the marker file holds the
    # suffix and the app only concatenates — a hand-run `rails
    # console` must arrive at byte-identical names with no truncation
    # logic of its own. Returns nil when even a hash-shortened suffix
    # cannot fit (a base name so long no suffix follows it); callers
    # name the problem instead of guessing.
    def fit_suffix(suffix, dir, base_databases)
      longest = base_databases.map { |d| d.to_s.bytesize }.max || 0
      budget = MAX_IDENTIFIER_BYTES - longest - 1
      return suffix if budget.positive? && suffix.bytesize <= budget
      return nil if budget < 8

      keep = budget - 7
      "#{suffix.byteslice(0, keep).gsub(/_+\z/, "")}_#{short_hash(dir)}"
    end

    # The actual database name for one base under a suffix. Raises
    # rather than truncating: silent truncation would diverge from
    # what the marker file produces inside the app, and yamine names
    # and app names disagreeing is exactly the bug this prevents.
    # fit_suffix makes this unreachable for fitted suffixes; the
    # raise guards programmatic misuse.
    def multiname(base_database, suffix)
      name = "#{base_database}_#{suffix}"
      raise ArgumentError,
        "database name exceeds #{MAX_IDENTIFIER_BYTES} bytes: #{name}" if name.bytesize > MAX_IDENTIFIER_BYTES

      name
    end

    def write_marker(dir, suffix)
      File.write(File.join(dir, MARKER_FILE), "#{suffix}\n")
    end

    def read_marker(dir)
      path = File.join(dir, MARKER_FILE)
      File.file?(path) ? File.read(path).strip : nil
    end

    # Keep the marker out of `git status` without touching the
    # committed .gitignore: git's exclude file lives in the shared
    # git dir, so one entry covers every worktree of the repo.
    def exclude_marker(dir)
      out, status = Open3.capture2("git", "-C", dir, "rev-parse", "--git-path", "info/exclude")
      return unless status.success?

      path = out.strip
      path = File.expand_path(path, dir) unless path.start_with?("/")
      return if File.file?(path) && File.read(path).lines.any? { |l| l.strip == MARKER_FILE }

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts MARKER_FILE }
    rescue SystemCallError, IOError
      nil
    end

    # The DATABASE_URL template per-worktree names derive from: ENV
    # first, then the config's top-level env.clear, then per-process
    # env.clear (configs written before top-level env existed). Shared
    # by boot, `db create/drop`, and `worktree clean` so they all agree.
    # Takes anything responding to .env (resolver Result / Config) —
    # pass env_config for a bare Config.
    def template_for(resolved)
      source = if resolved.respond_to?(:env)
        resolved.env
      else
        resolved.env_config
      end
      top = source.is_a?(Hash) ? source["clear"] : nil
      from_top = top.is_a?(Hash) ? top["DATABASE_URL"] : nil
      return from_top if from_top && !from_top.to_s.strip.empty?

      processes = resolved.respond_to?(:processes) ? resolved.processes : {}
      env = processes.values.map { |e| e["env"] || {} }
      clear = env.map { |e| e["clear"] || {} }.reduce({}, :merge)
      clear["DATABASE_URL"]
    end

    # Databases whose worktree dirs no longer exist (for `worktree clean`).
    def orphaned(state_dir)
      load_map(state_dir).select { |_, v| !File.directory?(v["dir"]) }
    end

    # The multi-database claim under `key`, or nil — single-database
    # claims (and foreign keys) simply have no names, and every reader
    # falls back to the key itself as the one database name.
    def multi_claim(state_dir, key)
      info = load_map(state_dir)[key]
      info if info.is_a?(Hash) && info["names"].is_a?(Hash) && !info["names"].empty?
    end

    # Every [database_name, server_url] pair a claim stands for: N
    # pairs for a multi claim, nil for a legacy single claim (caller
    # falls back to the key + its own template lookup). bases may lag
    # names on older claims; a missing base falls back to the first —
    # all of an app's databases live on one server in every layout
    # yamine has seen.
    def claim_pairs(info)
      names = info.is_a?(Hash) ? info["names"] : nil
      return nil if names.nil? || names.empty?

      bases = info["bases"] || {}
      default = bases.values.first
      names.filter_map { |cfg, db| [db, (bases[cfg] || default)] }
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

    # Drop a database with an honest outcome. Returns :dropped,
    # :missing (the database did not exist — nothing to do, NOT an
    # error), or :failed (server unreachable, drop refused). The
    # distinction matters: `worktree clean` used to print "could not
    # drop — remove manually" for a database that never existed,
    # sending the user hunting for locks and permissions that were
    # never the problem.
    def drop(name, database_url)
      case adapter_for(database_url)
      when :postgres then pg_drop(name, database_url)
      when :mysql then mysql_drop(name, database_url)
      else :failed
      end
    end

    def pg_drop(name, database_url)
      reachable, exists = pg_state(name, database_url)
      return :missing if reachable && !exists
      return :failed unless reachable

      uri = URI.parse(database_url)
      # env as the FIRST positional (like ensure_postgres): Open3
      # forwards kwargs to spawn, and spawn has no env: option — as a
      # kwarg this raised ArgumentError on every real drop, crashing
      # teardown after the routes were already stopped.
      _out, status = Open3.capture2(pg_env(uri), "dropdb", name)
      return :dropped if status.success?

      reachable, exists = pg_state(name, database_url)
      reachable && exists ? :failed : :dropped
    rescue SystemCallError
      :failed
    end

    def mysql_drop(name, database_url)
      reachable, exists = mysql_state(name, database_url)
      return :missing if reachable && !exists
      return :failed unless reachable

      uri = URI.parse(database_url)
      _out, status = Open3.capture2("mysqladmin", *mysql_args(uri), "drop", name, "-f")
      return :dropped if status.success?

      reachable, exists = mysql_state(name, database_url)
      reachable && exists ? :failed : :dropped
    rescue SystemCallError
      :failed
    end

    # [server_reachable, database_exists] — the split that lets drop
    # tell "nothing to drop" apart from "could not reach the server".
    def pg_state(name, database_url)
      uri = URI.parse(database_url)
      out, status = Open3.capture2(pg_env(uri), "psql", "-lqt")
      return [false, false] unless status.success?

      [true, out.split("\n").any? { |l| l.split("|").first.to_s.strip == name }]
    rescue SystemCallError
      [false, false]
    end

    def mysql_state(name, database_url)
      uri = URI.parse(database_url)
      out, status = Open3.capture2("mysql", *mysql_args(uri), "-e", "SHOW DATABASES;")
      return [false, false] unless status.success?

      [true, out.split("\n").include?(name)]
    rescue SystemCallError
      [false, false]
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

    # PGHOST only when the URL names a host: an empty authority
    # (postgres:///dbname) means the unix socket, and forcing
    # 127.0.0.1 there would reach the wrong server — or none.
    def pg_env(uri)
      {
        "PGHOST" => (uri.host unless uri.host.to_s.empty?),
        "PGPORT" => (uri.port || 5432).to_s,
        "PGUSER" => URI.decode_www_form_component(uri.user || ENV["USER"].to_s),
        "PGPASSWORD" => uri.password ? URI.decode_www_form_component(uri.password) : nil
      }.compact
    end
  end
end

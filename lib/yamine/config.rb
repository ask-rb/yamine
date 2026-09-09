# frozen_string_literal: true

require "erb"
require "yaml"

module Yamine
  # Mandatory config/local.yml — the ONLY source of truth for this app.
  #
  # Replaces the old optional JSON / inference / Procfile path with a
  # single file. Kamal patterns borrowed: YAML rendered through ERB,
  # validated against an example schema with context-pathed errors,
  # x- extensions ignored, deep overlay for variants (Kamal
  # destinations), env clear/secret split reading config/local.secrets.
  #
  # Shape:
  #
  #   service: myrr-chat
  #
  #   proxy:
  #     tld: localhost
  #     # host: myrr-chat.local.example.com
  #
  #   processes:
  #     web:
  #       cmd: bin/rails server -p $PORT
  #       proxy: true
  #       healthcheck: { path: /up, timeout: 30 }
  #     worker:
  #       cmd: bin/jobs
  #       proxy: false
  #
  #   env:
  #     clear:
  #       RAILS_ENV: development
  #     secret:
  #       - RAILS_MASTER_KEY
  #
  # Variant overlays: config/local.<variant>.yml deep-merged on top
  # (like Kamal's deploy.<destination>.yml). The `variant:` key in the
  # base file is not used — variants are files.
  class Config
    FILENAME = "local.yml"
    RELATIVE_DIR = "config"
    RELATIVE_PATH = File.join(RELATIVE_DIR, FILENAME)
    SECRETS_PATH = File.join(RELATIVE_DIR, "local.secrets")

    # Example schema: shapes the validator (types, required keys, array
    # element types). Unknown keys raise with the context path; keys
    # starting with "x-" are extensions and ignored (Kamal convention).
    EXAMPLE = {
      "service" => "myapp",
      "proxy" => {
        "tld" => "localhost",
        "host" => "myapp.local.example.com"
      },
      # db: false opts out of per-worktree databases entirely (exotic
      # setups: manual establish_connection, shared staging DB, ...).
      # Absent means enabled. A mapping holds future db options.
      "db" => false,
      "processes" => {
        "web" => {
          "cmd" => "bin/rails server -p $PORT",
          "proxy" => true,
          "healthcheck" => { "path" => "/up", "timeout" => 30 }
        }
      },
      "env" => {
        "clear" => { "RAILS_ENV" => "development" },
        "secret" => ["RAILS_MASTER_KEY"]
      }
    }.freeze

    REQUIRED_TOP = %w[service].freeze

    attr_reader :data, :dir, :path

    # Load config/local.yml for the app rooted at dir (walks up for the
    # nearest config/local.yml, so running from a subdirectory works).
    # Raises ConfigError when missing (mandatory) or invalid. The variant
    # overlay (config/local.<variant>.yml) is deep-merged on top when
    # YAMINE_VARIANT or the explicit variant arg is set.
    def self.load(dir = Dir.pwd, variant: nil, overlay: nil)
      variant ||= ENV["YAMINE_VARIANT"]
      overlay ||= ENV["YAMINE_OVERLAY"]
      root, config_path = find_root(dir)
      unless root
        return nil
      end

      data = load_yaml(config_path)
      if variant && !variant.to_s.strip.empty?
        overlay_path = File.join(root, RELATIVE_DIR, "local.#{variant.strip}.yml")
        if File.file?(overlay_path)
          overlay_data = load_yaml(overlay_path)
          data = deep_merge(data, overlay_data)
        end
      end
      if overlay && File.file?(overlay)
        overlay_data = load_yaml(overlay)
        data = deep_merge(data, overlay_data)
      end

      new(data, root, config_path)
    end

    def self.load_yaml(path)
      template = File.read(path)
      rendered = ERB.new(template, trim_mode: "-").result
      return {} if rendered.strip.empty?

      parsed = YAML.safe_load(rendered, aliases: true)
      raise ConfigError, "#{path} must be a YAML mapping" unless parsed.is_a?(Hash)

      parsed
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in #{path}: #{e.message}"
    end

    def self.find_root(dir)
      current = File.expand_path(dir)
      loop do
        candidate = File.join(current, RELATIVE_PATH)
        return [current, candidate] if File.file?(candidate)

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      nil
    end

    def self.missing_message(dir)
      "No #{RELATIVE_PATH} found from #{dir}. Run `yamine init`."
    end

    def self.deep_merge(base, overlay)
      base.merge(overlay) do |_, base_val, overlay_val|
        if base_val.is_a?(Hash) && overlay_val.is_a?(Hash)
          deep_merge(base_val, overlay_val)
        else
          overlay_val
        end
      end
    end

    def initialize(data, dir, path)
      @data = data
      @dir = dir
      @path = path
      validate!
    end

    def service
      data["service"].to_s
    end

    def proxy_config
      data["proxy"] || {}
    end

    def processes
      data["processes"] || {}
    end

    def env_config
      data["env"] || {}
    end

    # Secrets read from config/local.secrets (dotenv), gitignored.
    # Only needed when env.secret lists keys; missing file is not an
    # error until a listed secret is referenced.
    def secrets
      @secrets ||= load_secrets
    end

    def [](key)
      data[key]
    end

    private

    def load_secrets
      secrets_file = File.join(dir, SECRETS_PATH)
      return {} unless File.file?(secrets_file)

      parse_dotenv(File.read(secrets_file))
    rescue SystemCallError
      {}
    end

    def parse_dotenv(content)
      result = {}
      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        if line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/)
          result[Regexp.last_match(1)] = Regexp.last_match(2).strip.gsub(/\A["']|["']\z/, "")
        end
      end
      result
    end

    def app_config(package_dir = dir)
      # Monorepo: walk up looking for config/local.yml with apps map.
      # Falls back to top-level fields for non-monorepo usage.
      return data unless data["apps"].is_a?(Hash)
      require "pathname"
      rel = begin
        Pathname.new(File.expand_path(package_dir))
          .relative_path_from(Pathname.new(File.expand_path(dir))).to_s
      rescue ArgumentError
        nil
      end
      return data unless rel
      candidate = rel
      loop do
        entry = data["apps"][candidate]
        return entry if entry.is_a?(Hash)
        parent = File.dirname(candidate)
        break if parent == "." || parent == candidate
        candidate = parent
      end
      data
    end

    def validate!
      # Unknown top-level keys (outside example + x- extensions).
      unknown = data.keys.map(&:to_s) - EXAMPLE.keys.map(&:to_s)
      unknown.reject! { |k| k.start_with?("x-") }
      unless unknown.empty?
        raise ConfigError, "Unknown key(s) #{unknown.map(&:inspect).join(", ")} in #{@path}"
      end
      REQUIRED_TOP.each do |key|
        raise ConfigError, %("#{key}" is required in #{@path}) if data[key].nil? || data[key].to_s.strip.empty?
      end

      Validator.new(data, EXAMPLE, context: @path).validate!

      validate_service(data["service"], @path)
      if data["proxy"]
        validate_proxy(data["proxy"], "#{@path} proxy")
      end
      if data.key?("db")
        validate_db(data["db"], "#{@path} db")
      end
      if data["processes"]
        validate_processes(data["processes"], "#{@path} processes")
      end
      if data["env"]
        validate_env(data["env"], "#{@path} env")
      end
    end

    def validate_service(value, context)
      unless value.is_a?(String) && !value.strip.empty?
        raise ConfigError, "#{context}: service must be a non-empty string"
      end
    end

    def validate_proxy(value, context)
      raise ConfigError, "#{context} must be a mapping" unless value.is_a?(Hash)

      if value["host"] && !value["host"].is_a?(String)
        raise ConfigError, "#{context}: host must be a string"
      end
      if value["tld"] && !value["tld"].is_a?(String)
        raise ConfigError, "#{context}: tld must be a string"
      end
      if value.key?("host") && value.key?("tld")
        raise ConfigError, "#{context}: specify one of host or tld, not both"
      end
      if value["tld"] && !Sanitize.valid_tld?(value["tld"].downcase)
        raise ConfigError, "#{context}: invalid tld #{value["tld"].inspect}"
      end
    end

    def validate_db(value, context)
      return if value == false
      raise ConfigError, "#{context} must be false or a mapping" unless value.is_a?(Hash)
    end

    def validate_processes(value, context)
      raise ConfigError, "#{context} must be a mapping" unless value.is_a?(Hash)
      raise ConfigError, "#{context} must list at least one process" if value.empty?

      value.each do |name, entry|
        raise ConfigError, %("#{context}/#{name}" must be a mapping) unless entry.is_a?(Hash)

        if entry["cmd"].nil? || entry["cmd"].to_s.strip.empty?
          raise ConfigError, %("#{context}/#{name}" requires a non-empty cmd)
        end
        if entry.key?("proxy") && ![true, false].include?(entry["proxy"])
          raise ConfigError, %("#{context}/#{name} proxy must be a boolean")
        end
        if entry["healthcheck"]
          hc = entry["healthcheck"]
          raise ConfigError, %("#{context}/#{name} healthcheck must be a mapping) unless hc.is_a?(Hash)

          if hc.key?("path") && !hc["path"].is_a?(String)
            raise ConfigError, %("#{context}/#{name} healthcheck path must be a string)
          end
          if hc.key?("timeout") && !hc["timeout"].is_a?(Integer)
            raise ConfigError, %("#{context}/#{name} healthcheck timeout must be an integer)
          end
        end
      end
    end

    def validate_env(value, context)
      raise ConfigError, "#{context} must be a mapping" unless value.is_a?(Hash)

      if value["clear"] && !value["clear"].is_a?(Hash)
        raise ConfigError, "#{context} clear must be a mapping"
      end
      if value["secret"] && !value["secret"].is_a?(Array)
        raise ConfigError, "#{context} secret must be an array of strings"
      end
      if value["secret"] && !value["secret"].all? { |k| k.is_a?(String) }
        raise ConfigError, "#{context} secret keys must be strings"
      end
    end

    # Generic schema validator with context-pathed errors (Kamal
    # Validator pattern): walks the example shape, type-checks each
    # present key, and reports the path where the mismatch was found.
    class Validator
      def initialize(config, example, context:)
        @config = config
        @example = example
        @context = context
        @stack = []
      end

      def validate!
        validate_against_example!(@config, @example)
      end

      private

      def validate_against_example!(config, example)
        return unless example.is_a?(Hash) && config.is_a?(Hash)

        # Only validate keys the config actually has; absent example
        # keys are optional (Kamal ignores missing optional keys).
        config.each do |key, value|
          next if key.to_s.start_with?("x-")

          with_context(key) do
            example_value = example[key] || example[key.to_s]
            next if example_value.nil? && !example.key?(key.to_s) && !example.key?(key)

            validate_value!(value, example_value)
          end
        end
      end

      def validate_value!(value, example_value)
        return if example_value == "..."

        if example_value.is_a?(Hash) && value.is_a?(Hash)
          validate_against_example!(value, example_value)
        elsif example_value.is_a?(Array) && value.is_a?(Array)
          validate_array_of!(value, example_value.first.class) unless example_value.empty?
        elsif !example_value.nil?
          expected = type_description(example_value.class)
          unless value.is_a?(example_value.class) || (example_value.is_a?(String) && value.is_a?(String))
            raise ConfigError, "#{current_context}: expected #{expected}, got #{value.class.name.downcase}"
          end
        end
      end

      def validate_array_of!(array, type)
        array.each_with_index do |value, index|
          with_context(index) do
            unless value.is_a?(type)
              raise ConfigError, "#{current_context}: expected #{type.name.downcase}, got #{value.class.name.downcase}"
            end
          end
        end
      end

      def type_description(type)
        if type == Integer || type == Array
          "an #{type.name.downcase}"
        elsif type == TrueClass || type == FalseClass
          "a boolean"
        else
          "a #{type.name.downcase}"
        end
      end

      def with_context(part)
        @stack.push(part)
        yield
      ensure
        @stack.pop
      end

      def current_context
        ([@context] + @stack.map(&:to_s)).join("/")
      end
    end
  end
end

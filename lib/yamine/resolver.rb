# frozen_string_literal: true

module Yamine
  # Resolve hostnames from config/local.yml — the ONLY source of truth.
  # No inference, no Procfile fallback, no ENV for naming. If the file
  # is missing, resolve raises ConfigError telling the user to run
  # `yamine init`.
  module Resolver
    module_function

    Result = Struct.new(:app, :tld, :host, :processes, :secrets,
      :sources, :variant, :db, :env, keyword_init: true)

    def resolve(dir = Dir.pwd, variant: nil, tld: nil, host: nil)
      config = Config.load(dir, variant: variant)
      unless config
        raise ConfigError, Config.missing_message(dir)
      end

      service = config.service
      proxy = config.proxy_config
      processes = config.processes

      variant_name = (variant || ENV["YAMINE_VARIANT"])&.strip
      variant_name = nil if variant_name&.empty?

      # host or tld: config proxy.host wins over proxy.tld; flags override.
      if host || proxy["host"]
        effective_host = (host || proxy["host"]).to_s.strip.downcase
        effective_tld = nil
      else
        effective_tld = (tld || proxy["tld"] || Hostname::DEFAULT_TLD).to_s.strip.downcase
        effective_tld = effective_tld.gsub(/\A\./, "")
        unless Sanitize.valid_tld?(effective_tld)
          raise ConfigError, "Invalid tld #{effective_tld.inspect} in #{config.path} proxy.tld"
        end
        effective_host = nil
      end

      sources = {
        app: config.path.to_s,
        tld: proxy["tld"] ? "#{config.path} proxy.tld" : "default (localhost)",
        host: proxy["host"] ? "#{config.path} proxy.host" : nil,
        variant: variant_name ? "config/local.#{variant_name}.yml" : nil
      }

      Result.new(
        app: Sanitize.hostname_label(service),
        tld: effective_tld,
        host: effective_host,
        processes: processes,
        secrets: config.secrets,
        sources: sources,
        variant: variant_name,
        db: config.data["db"],
        env: config.env_config
      )
    end

    # Hostname for one process: primary (first proxy:true) is bare;
    # others are proc.app.tld; proxy:false have none.
    def hostname_for(result, proc_name)
      entry = result.processes[proc_name]
      return nil unless entry
      return nil if entry["proxy"] == false

      base = result.host ? result.host : "#{result.app}.#{result.tld}"
      proc_name.to_s == primary_proc(result) ? base : "#{proc_name}.#{base}"
    end

    def primary_proc(result)
      result.processes.find { |_, v| v["proxy"] != false }&.first
    end

    # All HTTP hostnames (for route registration / doctor).
    def hostnames(result)
      result.processes.filter_map { |name, entry|
        next if entry["proxy"] == false

        hostname_for(result, name)
      }
    end

    def url_for(result, proc_name, port:, tls:)
      host = hostname_for(result, proc_name)
      host && Hostname.url(host, port: port, tls: tls)
    end

    # Effective URL list for display (status): primary bare, others prefixed.
    def urls(result, port:, tls:)
      hostnames(result).map { |h| Hostname.url(h, port: port, tls: tls) }
    end
  end
end

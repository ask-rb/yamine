# frozen_string_literal: true

module Yamine
  # Resolve hostnames from config/local.yml — the ONLY source of truth.
  # No inference, no Procfile fallback, no ENV for naming. If the file
  # is missing, resolve raises ConfigError telling the user to run
  # `yamine init`.
  module Resolver
    module_function

    Result = Struct.new(:app, :tld, :host, :processes, :secrets,
      :sources, :variant, :overlay, :db, :env, keyword_init: true)

    # Two axes, and keeping them apart is the whole point:
    #
    #   overlay — an explicit `config/local.<name>.yml` to deep-merge.
    #             Only --variant / YAMINE_VARIANT ever set it, so a
    #             branch name can never select config by surprise.
    #   variant — the leading hostname label, from that same explicit
    #             name OR a linked worktree's branch. It is a name, not
    #             a file: a worktree is reachable at
    #             <branch>.<app>.localhost without inventing config.
    #
    # They share a value when the user asks for one explicitly. Only
    # then does a variant mean both "merge this file" and "prefix this
    # hostname", which is the documented `--variant` behavior.
    def resolve(dir = Dir.pwd, variant: nil, tld: nil, host: nil, use_branch: false)
      overlay = (variant || ENV["YAMINE_VARIANT"])&.strip
      overlay = nil if overlay&.empty?

      config = Config.load(dir, variant: overlay)
      unless config
        raise ConfigError, Config.missing_message(dir)
      end

      service = config.service
      proxy = config.proxy_config
      processes = config.processes

      variant_name, variant_source = Variant.resolve(dir, explicit: variant, use_branch: use_branch)

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
        variant: variant_source,
        overlay: overlay ? "config/local.#{overlay}.yml" : nil
      }

      Result.new(
        app: Sanitize.hostname_label(service),
        tld: effective_tld,
        host: effective_host,
        processes: processes,
        secrets: config.secrets,
        sources: sources,
        variant: variant_name,
        overlay: overlay,
        db: config.data["db"],
        env: config.env_config
      )
    end

    # Hostname for one process: primary (first proxy:true) is bare;
    # others are proc.app.tld; proxy:false have none. A variant — the
    # explicit name or a worktree's branch — leads every one of them.
    def hostname_for(result, proc_name)
      entry = result.processes[proc_name]
      return nil unless entry
      return nil if entry["proxy"] == false

      # An explicit proxy.host is a full hostname, so composition does
      # not apply — and a variant must never silently rewrite a host
      # the user wrote out in full.
      if result.host
        return proc_name.to_s == primary_proc(result) ? result.host : "#{proc_name}.#{result.host}"
      end

      Hostname.compose(
        app: result.app,
        tld: result.tld,
        service: (proc_name.to_s == primary_proc(result) ? nil : proc_name.to_s),
        variant: result.variant
      )
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

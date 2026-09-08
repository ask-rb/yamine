# frozen_string_literal: true

module Yamine
  # Hostname composition: {variant}.{service}.{app}.{tld}
  #
  # Each axis is independent. The web service is bare (myapp.localhost);
  # any other service prefixes (api.myapp.localhost). A variant prefixes
  # everything (fix-ui.myapp.localhost, fix-ui.api.myapp.localhost).
  # An explicit full hostname bypasses composition entirely.
  module Hostname
    DEFAULT_TLD = "localhost"

    module_function

    # Build hostnames for every configured TLD.
    def build(app:, tlds: [DEFAULT_TLD], service: nil, variant: nil)
      tld_list = Array(tlds).flatten.compact
      tld_list = [DEFAULT_TLD] if tld_list.empty?
      tld_list.map { |tld| compose(app: app, tld: tld, service: service, variant: variant) }
    end

    def compose(app:, tld:, service: nil, variant: nil)
      parts = [app.to_s]
      # The web service is bare (myapp.localhost); every other service
      # prefixes (api.myapp.localhost). "web" is the default service.
      svc = service.to_s
      parts.unshift(svc) if !svc.empty? && svc != "web"
      parts.unshift(variant.to_s) if variant && !variant.to_s.empty?
      "#{parts.join(".")}.#{tld}"
    end

    def url(hostname, port:, tls:)
      scheme = tls ? "https" : "http"
      default_port = tls ? 443 : 80
      suffix = (port == default_port) ? "" : ":#{port}"
      "#{scheme}://#{hostname}#{suffix}"
    end

    # Strip an explicit :port from a Host header for routing.
    def strip_port(authority)
      authority.to_s.split(":").first.to_s.downcase
    end
  end
end

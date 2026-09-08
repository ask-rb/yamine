# frozen_string_literal: true

require_relative "ask/local/version"
require_relative "ask/local/errors"
require_relative "ask/local/sanitize"
require_relative "ask/local/hostname"
require_relative "ask/local/inference"
require_relative "ask/local/variant"
require_relative "ask/local/framework"
require_relative "ask/local/config"
require_relative "ask/local/ownership"
require_relative "ask/local/command"
require_relative "ask/local/log"
require_relative "ask/local/route_store"
require_relative "ask/local/certs"
require_relative "ask/local/ports"
require_relative "ask/local/hosts"
require_relative "ask/local/proxy"
require_relative "ask/local/proxy_control"
require_relative "ask/local/supervisor"
require_relative "ask/local/runner"
require_relative "ask/local/resolver"
require_relative "ask/local/trust"
require_relative "ask/local/doctor"
require_relative "ask/local/cli/context"
require_relative "ask/local/procfile"
require_relative "ask/local/cli/boot"
require_relative "ask/local/cli/routes"
require_relative "ask/local/cli/system"
require_relative "ask/local/cli"

# Stable named .localhost URLs for Ruby development.
#
# Ask::Local replaces memorized ports with stable hostnames:
# `ask-local` in your app dir boots it at https://<app>.localhost.
module Ask
  module Local
  end
end

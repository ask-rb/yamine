# frozen_string_literal: true

require_relative "yamine/version"
require_relative "yamine/errors"
require_relative "yamine/agent"
require_relative "yamine/database"
require_relative "yamine/sanitize"
require_relative "yamine/hostname"
require_relative "yamine/inference"
require_relative "yamine/variant"
require_relative "yamine/framework"
require_relative "yamine/config"
require_relative "yamine/ownership"
require_relative "yamine/command"
require_relative "yamine/log"
require_relative "yamine/route_store"
require_relative "yamine/certs"
require_relative "yamine/ports"
require_relative "yamine/hosts"
require_relative "yamine/proxy"
require_relative "yamine/proxy_control"
require_relative "yamine/supervisor"
require_relative "yamine/runner"
require_relative "yamine/readiness"
require_relative "yamine/resolver"
require_relative "yamine/trust"
require_relative "yamine/doctor"
require_relative "yamine/cli/context"
require_relative "yamine/procfile"
require_relative "yamine/cli/boot"
require_relative "yamine/cli/routes"
require_relative "yamine/cli/system"
require_relative "yamine/cli"

# Stable named .localhost URLs for Ruby development.
#
# Yamine replaces memorized ports with stable hostnames:
# `yamine` in your app dir boots it at https://<app>.localhost.
module Yamine
end

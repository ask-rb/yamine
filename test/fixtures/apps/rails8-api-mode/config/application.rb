require_relative "boot"
require "rails"
require "action_controller/railtie"

module Rails8ApiMode
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = false
    config.secret_key_base = "dev-secret-key-for-fixture"
  end
end

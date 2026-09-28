require "roda"

class PluginApp < Roda
  plugin :common_logger
  plugin :default_headers,
    "Content-Type" => "text/plain",
    "X-Frame-Options" => "deny"
  plugin :head
  plugin :status_handler

  status_handler(404) { "plugin-404" }

  route do |r|
    r.root { "roda-plugins:#{env["HTTP_HOST"]}" }
  end
end

run PluginApp.app

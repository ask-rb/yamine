# frozen_string_literal: true

# Hanami 2 slice layout (without the hanami gem): config/app boots the
# container, slices live under slices/. Detection reads :rack via
# config.ru; the runner boots whatever config.ru runs.
module Hanami2App
  class App
    def call(env)
      [200, { "Content-Type" => "text/plain" }, ["hanami2:#{env["HTTP_HOST"]}"]]
    end
  end
end

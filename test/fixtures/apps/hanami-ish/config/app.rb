# frozen_string_literal: true

module HanamiIsh
  class App
    def call(env)
      [200, { "Content-Type" => "text/plain" }, ["hanami-ish:#{env["HTTP_HOST"]}"]]
    end
  end
end

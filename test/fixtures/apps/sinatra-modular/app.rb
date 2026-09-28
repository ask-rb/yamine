require "sinatra/base"

class ModularApp < Sinatra::Base
  get("/") { "sinatra-modular:#{request.host}" }
end

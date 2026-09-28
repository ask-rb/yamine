require "sinatra"

set :bind, "127.0.0.1"

get "/" do
  "sinatra-classic:#{request.host}"
end

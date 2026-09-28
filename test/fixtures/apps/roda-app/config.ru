require "roda"

class RodaApp < Roda
  route do |r|
    r.root { "roda-app:#{env["HTTP_HOST"]}" }
  end
end

run RodaApp.app

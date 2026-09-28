Rails.application.routes.draw do
  root to: ->(env) { [200, { "Content-Type" => "text/plain" }, ["rails8-min-body"]] }
end

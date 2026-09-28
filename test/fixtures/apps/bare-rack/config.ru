run ->(env) { [200, { "Content-Type" => "text/plain" }, ["bare-rack:#{env["HTTP_HOST"]}"]] }

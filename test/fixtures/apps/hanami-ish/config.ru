# Slice-style app (Hanami 2 layout) without the hanami gem installed:
# detection must still classify it as a Rack app via config.ru.
require_relative "config/app"

run HanamiIsh::App.new

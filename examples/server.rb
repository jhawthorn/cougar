#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "cougar"
require "rack"

# Load the Rack app from config.ru
app, _options = Rack::Builder.parse_file("examples/config.ru")

# Start the server (uses RUBY_MAX_CPU env var or defaults to 8 workers)
server = Cougar::Server.new(app, host: "0.0.0.0", port: 9292)

trap("INT") do
  puts "\nShutting down..."
  server.stop
  exit
end

server.run
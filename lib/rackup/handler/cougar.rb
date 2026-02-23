# frozen_string_literal: true

require "cougar"

module Rackup
  module Handler
    module Cougar
      def self.run(app, **options)
        host = options[:Host] || "localhost"
        port = Integer(options[:Port] || 9292)

        server = ::Cougar::Server.new(app, host: host, port: port)
        yield server if block_given?
        server.run
      end

      def self.valid_options
        {
          "Host=HOST" => "Hostname to listen on (default: localhost)",
          "Port=PORT" => "Port to listen on (default: 9292)"
        }
      end
    end

    register :cougar, Cougar
  end
end

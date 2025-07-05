# frozen_string_literal: true

require "socket"

module Cougar
  class Server
    attr_reader :host, :port, :app, :workers

    def initialize(app, host: "localhost", port: 9292, workers: ENV.fetch("RUBY_MAX_CPU", 8).to_i)
      @app = app
      @host = host
      @port = port
      @workers = workers
      @server = nil
      @worker_ractors = []
    end

    def start
      @server = TCPServer.new(@host, @port)
      puts "Cougar listening on #{@host}:#{@port} with #{@workers} workers"

      # Freeze the app so it can be shared across Ractors
      @app.freeze

      close_ports = Ractor::Port.new

      # Create worker Ractors
      @workers.times do |i|
        worker = Ractor.new(@server, @app, i, close_ports) do |server, app, worker_id, close_ports|

          close_port = Ractor::Port.new
          worker_thread = Thread.current
          Thread.new do |th|
            close_port.receive
            server.close
          end
          close_ports << close_port

          loop do
            begin
              client = server.accept
            rescue IOError, Errno::EBADF => e
              # Server socket was closed, exit gracefully
              break
            end

            begin
              # Create a new Request instance for this connection
              request = Cougar::Request.new(client)

              # Parse the HTTP request
              if request.parse
                # Call the Rack app
                status, headers, body = app.call(request.env)

                # Send the response
                request.respond(status, headers, body)
              end
            rescue => e
            end
          end

        end

        @worker_ractors << worker
      end

      @close_ports = @workers.times.map { close_ports.receive }

      # Wait for interrupt
      sleep
    end

    def stop
      @server&.close

      @close_ports.each { |port| port.send(:close) }

      # Wait for workers to finish
      @worker_ractors.each(&:join)
    end
  end
end

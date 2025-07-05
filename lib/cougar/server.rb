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

      # Create worker Ractors
      @workers.times do |i|
        worker = Ractor.new(@server, @app, i) do |server, app, worker_id|
          puts "Worker #{worker_id} started"
          
          loop do
            begin
              client = server.accept
              
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
              puts "Worker #{worker_id} error: #{e.message}"
              puts e.backtrace.first(5)
            end
          end
        end
        
        @worker_ractors << worker
      end

      # Wait for interrupt
      sleep
    end

    def stop
      @server&.close
    end
  end
end
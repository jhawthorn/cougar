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
      silence_ractor_warning!

      @server = TCPServer.new(@host, @port)
      @port = @server.addr[1]  # Get the actual port if it was 0
      puts "Cougar listening on #{@host}:#{@port} with #{@workers} workers"

      # Freeze the app so it can be shared across Ractors
      @app.freeze

      control_ports = Ractor::Port.new

      # Create worker Ractors
      @workers.times do |i|
        worker = Ractor.new(@server, @app, i, control_ports) do |server, app, worker_id, control_ports|

          control_port = Ractor::Port.new
          worker_thread = Thread.current
          control_thread = Thread.new do |th|
            control_port.receive
            server.close
          end
          control_ports << control_port

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
              $stderr.puts "[Worker #{worker_id}] #{e.class}: #{e.message}"
              $stderr.puts e.backtrace
            ensure
              client.close
            end
          end

          control_thread.join
          puts "stopped worker #{worker_id}"
        end

        @worker_ractors << worker
      end

      @control_ports = @workers.times.map { control_ports.receive }
    end

    def run
      start
      sleep
    end

    def stop
      @server.close

      @control_ports.each { |port| port.send(:close) }

      # Wait for workers to finish
      @worker_ractors.each(&:join)
    end

    private

    def silence_ractor_warning!
      warning_was = Warning[:experimental]
      Warning[:experimental] = false
      Ractor.new{}.join
      Warning[:experimental] = warning_was
    end
  end
end

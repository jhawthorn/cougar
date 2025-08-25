# frozen_string_literal: true

require "socket"
require_relative "ractor_worker"

module Cougar
  class Server
    attr_reader :host, :port, :app, :workers

    def initialize(app, host: "localhost", port: 9292, workers: ENV.fetch("RUBY_MAX_CPU", 8).to_i)
      @app = app
      @host = host
      @port = port
      @workers = workers
      @server = nil
      @workers_list = []
    end

    def start
      silence_ractor_warning!

      @server = TCPServer.new(@host, @port)
      @port = @server.addr[1]  # Get the actual port if it was 0
      puts "Cougar listening on #{@host}:#{@port} with #{@workers} workers"

      # Freeze the app so it can be shared across Ractors
      @app.freeze

      # Create worker Ractors
      @workers.times do |i|
        worker = RactorWorker.new(i, @server, @app)
        @workers_list << worker
      end
    end

    def run
      start

      # Wait for workers to finish
      @workers_list.each(&:join)
    end

    def stop
      @server.close

      @workers_list.each(&:stop)
    end

    def status
      response_port = Ractor::Port.new
      workers = @workers_list
      workers.each { |worker| worker.send_status_request(response_port) }
      statuses = workers.size.times.map { response_port.receive }
      response_port.close
      statuses
    end

    def inspect
      worker_statuses = status
      "#<#{self.class.name}:0x#{object_id.to_s(16)} @host=#{@host.inspect} @port=#{@port} @workers=#{@workers} workers=#{worker_statuses.inspect}>"
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

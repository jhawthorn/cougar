require 'optparse'
require 'cougar'
require 'rack'

module Cougar
  class CLI
    def initialize(argv)
      @argv = argv
      @options = {
        host: "localhost",
        port: 9292,
        config: "config.ru"
      }
    end

    def run
      parse_options!
      
      if @options[:version]
        puts "Cougar version #{Cougar::VERSION}"
        return
      end

      if @options[:help]
        puts @parser
        return
      end

      start_server
    end

    private

    def parse_options!
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: cougar [options] [config.ru]"

        opts.on("-p", "--port PORT", Integer, "Port to bind to (default: 9292)") do |port|
          @options[:port] = port
        end

        opts.on("-b", "--bind HOST", "Host to bind to (default: localhost)") do |host|
          @options[:host] = host
        end

        opts.on("-w", "--workers NUM", Integer, "Number of worker processes") do |workers|
          @options[:workers] = workers
        end

        opts.on("-v", "--version", "Print version and exit") do
          @options[:version] = true
        end

        opts.on("-h", "--help", "Show this help message") do
          @options[:help] = true
        end
      end

      @parser.parse!(@argv)

      # After parse!, @argv contains only non-option arguments
      if @argv.first
        @options[:config] = @argv.first
      end
    end

    def start_server
      _, max_file_limit = Process.getrlimit(Process::RLIMIT_NOFILE)
      Process.setrlimit(Process::RLIMIT_NOFILE, max_file_limit)

      # Load the Rack app
      app, _options = Rack::Builder.parse_file(@options[:config])

      # Create server options
      server_options = {
        host: @options[:host],
        port: @options[:port]
      }
      
      server_options[:workers] = @options[:workers] if @options[:workers]

      # Start the server
      server = Cougar::Server.new(app, **server_options)
      
      puts "Starting Cougar server on http://#{@options[:host]}:#{@options[:port]}"
      puts "* Workers: #{server_options[:workers] || ENV.fetch("RUBY_MAX_CPU", 8)}"
      puts "* Loading app from: #{@options[:config]}"
      
      trap("INT") do
        puts "\nShutting down..."
        server.stop
      end

      server.run
    end
  end
end

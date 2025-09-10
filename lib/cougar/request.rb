# frozen_string_literal: true

require "stringio"
require "llhttp"
require_relative "http_statuses"

module Cougar
  SERVER_SOFTWARE = "Cougar/#{VERSION}".freeze

  class RequestDelegate < LLHttp::Delegate
    attr_reader :env, :complete

    def initialize
      @env = {}
      @headers = {}
      @body = String.new
      @complete = false
      @current_header = nil
    end

    def on_message_begin
      @headers.clear
      @body = String.new
      @env.clear
      @complete = false
    end

    def on_url(url)
      @env["REQUEST_URI"] = url
      path, query = url.split("?", 2)
      @env["PATH_INFO"] = path || "/"
      @env["QUERY_STRING"] = query || ""
    end

    def on_header_field(field)
      @current_header = field
    end

    def on_header_value(value)
      @headers[@current_header] = value if @current_header
    end

    def on_headers_complete
      @env["SCRIPT_NAME"] = ""

      # Extract SERVER_NAME and SERVER_PORT from Host header
      if @headers["Host"]
        host, port = @headers["Host"].split(":", 2)
        @env["SERVER_NAME"] = host
        @env["SERVER_PORT"] = port || "80"
      else
        @env["SERVER_NAME"] = "localhost"
        @env["SERVER_PORT"] = "80"
      end

      @env["rack.version"] = [1, 3]
      @env["rack.url_scheme"] = "http"
      @env["rack.errors"] = $stderr
      @env["rack.multithread"] = false
      @env["rack.multiprocess"] = true
      @env["rack.run_once"] = false

      # Convert headers to Rack format
      @headers.each do |name, value|
        # Skip Content-Type and Content-Length as they have special handling
        next if name == "Content-Type" || name == "Content-Length"

        key = "HTTP_#{name}"
        key.upcase!
        key.tr!("-", "_")
        @env[key] = value
      end

      # Handle special headers
      @env["CONTENT_TYPE"] = @headers["Content-Type"] if @headers["Content-Type"]
      @env["CONTENT_LENGTH"] = @headers["Content-Length"] if @headers["Content-Length"]
    end

    def on_body(chunk)
      @body << chunk
    end

    def on_message_complete
      @env["rack.input"] = StringIO.new(@body)
      @complete = true
    end
  end

  class Request
    def initialize(client)
      @client = client
      @delegate = RequestDelegate.new
      @parser = LLHttp::Parser.new(@delegate, type: :request)

      # Set REMOTE_ADDR from client socket
      if @client.respond_to?(:peeraddr)
        @delegate.env["REMOTE_ADDR"] = @client.peeraddr[3]
      else
        @delegate.env["REMOTE_ADDR"] = "127.0.0.1"
      end
    end

    def parse
      while !@delegate.complete && (data = fast_read(16384))
        @parser << data
      end

      @delegate.complete
    rescue EOFError
      @delegate.complete
    end

    def env
      # Add REQUEST_METHOD from parser
      @delegate.env["REQUEST_METHOD"] = @parser.method_name

      # Add SERVER_PROTOCOL
      @delegate.env["SERVER_PROTOCOL"] = "HTTP/#{@parser.http_major}.#{@parser.http_minor}"

      # Add SERVER_SOFTWARE
      @delegate.env["SERVER_SOFTWARE"] = SERVER_SOFTWARE

      @delegate.env
    end

    WRITE_TIMEOUT = 10
    READ_TIMEOUT = 10
    SOCKET_WRITE_ERR_MSG = "Socket timeout writing data"
    SOCKET_READ_ERR_MSG = "Socket timeout reading data"

    def fast_read(size)
      begin
        @client.read_nonblock(size)
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK
        unless @client.wait_readable(READ_TIMEOUT)
          raise SOCKET_READ_ERR_MSG
        end
        retry
      rescue Errno::EPIPE, SystemCallError, IOError
        raise SOCKET_READ_ERR_MSG
      end
    end

    def fast_write(str)
      n = 0
      byte_size = str.bytesize
      while n < byte_size
        begin
          n += @client.write_nonblock(n.zero? ? str : str.byteslice(n..-1))
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          unless @client.wait_writable(WRITE_TIMEOUT)
            raise SOCKET_WRITE_ERR_MSG
          end
          retry
        rescue Errno::EPIPE, SystemCallError, IOError
          raise SOCKET_WRITE_ERR_MSG
        end
      end
    end

    def respond(status, headers, body)
      fast_write("HTTP/1.1 #{status} #{status_text(status)}\r\n")

      headers.each do |name, value|
        fast_write("#{name}: #{value}\r\n")
      end
      fast_write("\r\n")

      body.each do |chunk|
        fast_write(chunk)
      end

      body.close if body.respond_to?(:close)
    ensure
      @client.close rescue nil
    end

    private

    def status_text(code)
      HttpStatuses.text_for(code)
    end
  end
end

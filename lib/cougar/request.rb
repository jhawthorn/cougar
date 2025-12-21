# frozen_string_literal: true

require "stringio"
require "picohttp"
require_relative "http_statuses"

module Cougar
  SERVER_SOFTWARE = "Cougar/#{VERSION}".freeze


  class Request
    def initialize(client)
      @client = client
      @buffer = String.new
      @env = nil
      @body_offset = nil
    end

    def parse
      # Read data until we have a complete HTTP request
      while @env.nil?
        data = fast_read(16384)
        break unless data

        @buffer << data

        # Try to parse the accumulated buffer
        @env = Picohttp.parse_request_env(@buffer)

        if @env
          # Find where headers end and body begins
          @body_offset = @buffer.index("\r\n\r\n")
          @body_offset += 4 if @body_offset
          break
        end
      end

      return false unless @env

      # Add additional Rack environment variables
      setup_rack_env

      # Handle request body if present
      setup_request_body

      true
    rescue EOFError
      false
    end

    def env
      @env
    end

    WRITE_TIMEOUT = 10
    READ_TIMEOUT = 10
    SOCKET_WRITE_ERR_MSG = "Socket timeout writing data"
    SOCKET_READ_ERR_MSG = "Socket timeout reading data"

    def fast_read(size)
      while true
        ret = @client.read_nonblock(size, exception: false)
        if ret == :wait_readable
          unless @client.wait_readable(READ_TIMEOUT)
            raise SOCKET_READ_ERR_MSG
          end
        else
          return ret
        end
      end
    end

    def fast_write(str)
      n = 0
      byte_size = str.bytesize
      while n < byte_size
        ret = @client.write_nonblock(n.zero? ? str : str.byteslice(n..-1), exception: false)
        if ret == :wait_writable
          unless @client.wait_writable(WRITE_TIMEOUT)
            raise SOCKET_WRITE_ERR_MSG
          end
        else
          n += ret
        end
      end
    end

    def respond(status, headers, body)
      fast_write("HTTP/1.1 #{status} #{status_text(status)}\r\n")

      should_keepalive = true
      if should_keepalive
        headers["Connection"] = "keep-alive"
      end

      if !headers["Content-Length"]
        old_body = body
        body = []
        length = 0
        old_body.each do |chunk|
          body << chunk
          length += chunk.bytesize
        end
        headers["Content-Length"] = length.to_s
      end

      header_str = +""
      headers.each do |name, value|
        header_str << "#{name}: #{value}\r\n"
      end
      header_str << "\r\n"
      fast_write(header_str)

      body.each do |chunk|
        fast_write(chunk)
      end

      body.close if body.respond_to?(:close)
    ensure
      unless should_keepalive
        @client.close rescue nil
      end
    end

    private

    def setup_rack_env
      # Set REMOTE_ADDR from client socket
      if @client.respond_to?(:peeraddr)
        @env["REMOTE_ADDR"] = @client.peeraddr[3]
      else
        @env["REMOTE_ADDR"] = "127.0.0.1"
      end

      # Add standard Rack environment variables
      @env["SCRIPT_NAME"] = ""
      @env["REQUEST_URI"] = @env["PATH_INFO"]
      @env["REQUEST_URI"] += "?#{@env["QUERY_STRING"]}" unless @env["QUERY_STRING"].empty?

      # Extract SERVER_NAME and SERVER_PORT from Host header
      if @env["HTTP_HOST"]
        host, port = @env["HTTP_HOST"].split(":", 2)
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

      # Add SERVER_SOFTWARE
      @env["SERVER_SOFTWARE"] = SERVER_SOFTWARE
    end

    def setup_request_body
      body_data = @buffer[@body_offset..-1] || ""

      # Read any remaining body data if Content-Length is specified
      if @env["CONTENT_LENGTH"]
        content_length = @env["CONTENT_LENGTH"].to_i
        while body_data.bytesize < content_length
          data = fast_read(16384)
          break unless data
          body_data << data
        end
      end

      @env["rack.input"] = StringIO.new(body_data)
    end

    def status_text(code)
      HttpStatuses.text_for(code)
    end
  end
end

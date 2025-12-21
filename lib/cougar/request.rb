# frozen_string_literal: true

require "stringio"
require "picohttp"
require_relative "http_statuses"
require_relative "rack/error_stream"
require_relative "rack/empty_input"

module Cougar
  SERVER_SOFTWARE = "Cougar/#{VERSION}".freeze


  class Request
    def initialize(client)
      @client = client
      @buffer = String.new
      @read_buf = String.new(capacity: 16384)
      reset_for_next_request
    end

    def reset_for_next_request
      if @body_offset
        content_length = @env&.fetch("CONTENT_LENGTH", "0").to_i
        consumed = @body_offset + content_length
        if consumed >= @buffer.bytesize
          @buffer.clear
        else
          @buffer = @buffer.byteslice(consumed, @buffer.bytesize - consumed)
        end
      end
      @env = nil
      @body_offset = nil
    end

    def has_buffered_data?
      !@buffer.empty?
    end

    def parse
      # Read data until we have a complete HTTP request
      while @env.nil?
        # Try to parse the accumulated buffer
        unless @buffer.empty?
          @env = Picohttp.parse_request_env(@buffer)

          if @env
            # Find where headers end and body begins
            @body_offset = @buffer.index("\r\n\r\n")
            @body_offset += 4 if @body_offset
            break
          end
        end

        # Need more data
        break unless fast_read(16384, @read_buf)

        @buffer << @read_buf
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

    def fast_read(size, buf)
      while true
        ret = @client.read_nonblock(size, buf, exception: false)
        if :wait_readable == ret
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
        if :wait_writable == ret
          unless @client.wait_writable(WRITE_TIMEOUT)
            raise SOCKET_WRITE_ERR_MSG
          end
        else
          n += ret
        end
      end
    end

    def respond(status, headers, body)
      if @env["SERVER_PROTOCOL"] == "HTTP/1.0"
        protocol = "HTTP/1.0"
        should_keepalive = false
      else
        protocol = "HTTP/1.1"
        should_keepalive = !@env["HTTP_CONNECTION"]&.casecmp?("close")
      end

      fast_write("#{protocol} #{status} #{status_text(status)}\r\n")

      headers["Connection"] = should_keepalive ? "keep-alive" : "close"

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

      should_keepalive
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
      if (host = @env["HTTP_HOST"])
        if (colon = host.byteindex(":"))
          @env["SERVER_NAME"] = host.byteslice(0, colon)
          @env["SERVER_PORT"] = host.byteslice(colon + 1, host.bytesize - colon - 1)
        else
          @env["SERVER_NAME"] = host
          @env["SERVER_PORT"] = "80"
        end
      else
        @env["SERVER_NAME"] = "localhost"
        @env["SERVER_PORT"] = "80"
      end

      @env["rack.version"] = [1, 3]
      @env["rack.url_scheme"] = "http"
      @env["rack.errors"] = Cougar::Rack::ERROR_STREAM
      @env["rack.multithread"] = false
      @env["rack.multiprocess"] = true
      @env["rack.run_once"] = false

      # Add SERVER_SOFTWARE
      @env["SERVER_SOFTWARE"] = SERVER_SOFTWARE
    end

    def setup_request_body
      content_length = @env["CONTENT_LENGTH"]&.to_i || 0

      if content_length == 0
        @env["rack.input"] = Cougar::Rack::EMPTY_INPUT
        return
      end

      body_data = @buffer.byteslice(@body_offset, @buffer.bytesize - @body_offset) || ""

      while body_data.bytesize < content_length
        break unless fast_read(16384, @read_buf)
        body_data << @read_buf
      end

      @env["rack.input"] = StringIO.new(body_data)
    end

    def status_text(code)
      HttpStatuses.text_for(code)
    end
  end
end

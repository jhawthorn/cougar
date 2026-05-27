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
      @remote_addr = client.respond_to?(:remote_address) ? client.remote_address.ip_address : "127.0.0.1"
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
        status_line = HttpStatuses.status_line_10(status)
        should_keepalive = false
      else
        status_line = HttpStatuses.status_line_11(status)
        should_keepalive = !@env["HTTP_CONNECTION"]&.casecmp?("close")
      end

      headers["connection"] = should_keepalive ? "keep-alive" : "close"

      if !headers["content-length"] && status >= 200 && status != 204 && status != 304
        old_body = body
        body = []
        length = 0
        old_body.each do |chunk|
          body << chunk
          length += chunk.bytesize
        end
        headers["content-length"] = length.to_s
      end

      buf = +""
      buf << status_line
      headers.each do |name, value|
        case value
        when Array
          value.each do |v|
            buf << name << ": " << v << "\r\n"
          end
        else
          buf << name << ": " << value << "\r\n"
        end
      end
      buf << "\r\n"

      body.each do |chunk|
        buf << chunk
      end
      fast_write(buf)

      body.close if body.respond_to?(:close)

      should_keepalive
    end

    RACK_ENV_CONST = {
      "rack.version" => [1, 3].freeze,
      "rack.url_scheme" => "http",
      "rack.errors" => Cougar::Rack::ERROR_STREAM,
      "rack.multithread" => false,
      "rack.multiprocess" => true,
      "rack.run_once" => false,
      "SERVER_SOFTWARE" => SERVER_SOFTWARE,
    }.freeze

    private

    def setup_rack_env
      @env["REMOTE_ADDR"] = @remote_addr
      @env.update(RACK_ENV_CONST)
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

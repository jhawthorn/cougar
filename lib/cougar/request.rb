# frozen_string_literal: true

require "stringio"
require "llhttp"

module Cougar
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
    end

    def parse
      while !@delegate.complete && (data = @client.readpartial(16384))
        @parser << data
      end

      @delegate.complete
    rescue EOFError
      @delegate.complete
    end

    def env
      # Add REQUEST_METHOD from parser
      @delegate.env["REQUEST_METHOD"] = @parser.method_name
      @delegate.env
    end

    def respond(status, headers, body)
      @client.write("HTTP/1.1 #{status} #{status_text(status)}\r\n")

      headers.each do |name, value|
        @client.write("#{name}: #{value}\r\n")
      end
      @client.write("\r\n")

      body.each do |chunk|
        @client.write(chunk)
      end

      body.close if body.respond_to?(:close)
    ensure
      @client.close rescue nil
    end

    private

    def status_text(code)
      case code
      when 200 then "OK"
      when 201 then "Created"
      when 204 then "No Content"
      when 301 then "Moved Permanently"
      when 302 then "Found"
      when 304 then "Not Modified"
      when 400 then "Bad Request"
      when 401 then "Unauthorized"
      when 403 then "Forbidden"
      when 404 then "Not Found"
      when 405 then "Method Not Allowed"
      when 500 then "Internal Server Error"
      when 502 then "Bad Gateway"
      when 503 then "Service Unavailable"
      else "Unknown"
      end
    end
  end
end

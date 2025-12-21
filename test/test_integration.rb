# frozen_string_literal: true

require "test_helper"
require "net/http"
require "json"
require "timeout"

class TestIntegration < Minitest::Test
  class TestApp
    def self.call(env)
      case env["PATH_INFO"]
      when "/"
        [200, {"Content-Type" => "text/plain"}, ["Hello World"]]
      when "/json"
        [200, {"Content-Type" => "application/json"}, ['{"message": "success"}']]
      when "/echo"
        body = env["rack.input"].read
        [200, {"Content-Type" => "text/plain"}, ["Method: #{env["REQUEST_METHOD"]}\nBody: #{body}"]]
      when "/headers"
        headers = env.select { |k, v| k.start_with?("HTTP_") }
                     .map { |k, v| "#{k}: #{v}" }
                     .join("\n")
        [200, {"Content-Type" => "text/plain"}, [headers]]
      when "/slow"
        sleep 0.1
        [200, {"Content-Type" => "text/plain"}, ["Slow response"]]
      else
        [404, {"Content-Type" => "text/plain"}, ["Not Found"]]
      end
    end
  end
  
  def setup
    @server = Cougar::Server.new(TestApp, host: "localhost", port: 0, workers: 2)
    @server.start
    @port = @server.port
  end
  
  def teardown
    @server&.stop
  end
  
  def test_simple_get_request
    response = Net::HTTP.get_response(URI("http://localhost:#{@port}/"))
    
    assert_equal "200", response.code
    assert_equal "Hello World", response.body
    assert_equal "text/plain", response["Content-Type"]
  end
  
  def test_json_response
    response = Net::HTTP.get_response(URI("http://localhost:#{@port}/json"))
    
    assert_equal "200", response.code
    assert_equal '{"message": "success"}', response.body
    assert_equal "application/json", response["Content-Type"]
    
    json = JSON.parse(response.body)
    assert_equal "success", json["message"]
  end
  
  def test_post_request_with_body
    uri = URI("http://localhost:#{@port}/echo")
    http = Net::HTTP.new(uri.host, uri.port)
    
    request = Net::HTTP::Post.new(uri)
    request.body = '{"test": "data"}'
    request["Content-Type"] = "application/json"
    
    response = http.request(request)
    
    assert_equal "200", response.code
    assert_includes response.body, "Method: POST"
    assert_includes response.body, 'Body: {"test": "data"}'
  end
  
  def test_put_request
    uri = URI("http://localhost:#{@port}/echo")
    http = Net::HTTP.new(uri.host, uri.port)
    
    request = Net::HTTP::Put.new(uri)
    request.body = "updated content"
    request["Content-Type"] = "text/plain"
    
    response = http.request(request)
    
    assert_equal "200", response.code
    assert_includes response.body, "Method: PUT"
    assert_includes response.body, "Body: updated content"
  end
  
  def test_custom_headers
    uri = URI("http://localhost:#{@port}/headers")
    http = Net::HTTP.new(uri.host, uri.port)
    
    request = Net::HTTP::Get.new(uri)
    request["X-Custom-Header"] = "custom-value"
    request["User-Agent"] = "TestAgent/1.0"
    
    response = http.request(request)
    
    assert_equal "200", response.code
    assert_includes response.body, "HTTP_X_CUSTOM_HEADER: custom-value"
    assert_includes response.body, "HTTP_USER_AGENT: TestAgent/1.0"
  end
  
  def test_404_response
    response = Net::HTTP.get_response(URI("http://localhost:#{@port}/nonexistent"))
    
    assert_equal "404", response.code
    assert_equal "Not Found", response.body
  end
  
  def test_query_parameters
    response = Net::HTTP.get_response(URI("http://localhost:#{@port}/echo?foo=bar&baz=qux"))
    
    assert_equal "200", response.code
    assert_includes response.body, "Method: GET"
  end
  
  def test_concurrent_requests
    threads = []
    responses = []
    
    10.times do |i|
      threads << Thread.new do
        response = Net::HTTP.get_response(URI("http://localhost:#{@port}/"))
        responses << response
      end
    end
    
    threads.each(&:join)
    
    assert_equal 10, responses.length
    responses.each do |response|
      assert_equal "200", response.code
      assert_equal "Hello World", response.body
    end
  end
  
  def test_large_post_body
    large_body = "x" * 10000
    
    uri = URI("http://localhost:#{@port}/echo")
    http = Net::HTTP.new(uri.host, uri.port)
    
    request = Net::HTTP::Post.new(uri)
    request.body = large_body
    request["Content-Type"] = "text/plain"
    
    response = http.request(request)
    
    assert_equal "200", response.code
    assert_includes response.body, "Method: POST"
    assert_includes response.body, "Body: #{large_body}"
  end
  
  def test_multiple_rapid_requests
    uri = URI("http://localhost:#{@port}/")

    responses = []
    100.times do
      response = Net::HTTP.get_response(uri)
      responses << response
    end

    responses.each do |response|
      assert_equal "200", response.code
      assert_equal "Hello World", response.body
    end
  end

  def test_keepalive
    uri = URI("http://localhost:#{@port}/")

    Net::HTTP.start(uri.host, uri.port) do |http|
      # Send multiple requests on the same connection
      5.times do
        request = Net::HTTP::Get.new(uri)
        response = http.request(request)

        assert_equal "200", response.code
        assert_equal "Hello World", response.body
        assert_equal "keep-alive", response["Connection"]
      end
    end
  end

  def test_pipelining
    socket = TCPSocket.new("localhost", @port)

    requests = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" * 3
    socket.write(requests)

    responses = []
    3.times do
      response = +""
      while (line = socket.gets) != "\r\n"
        response << line
      end
      if response =~ /Content-Length: (\d+)/i
        body = socket.read($1.to_i)
        response << "\r\n" << body
      end
      responses << response
    end

    socket.close

    assert_equal 3, responses.length
    responses.each do |response|
      assert_match(/HTTP\/1\.1 200/, response)
      assert_match(/Hello World/, response)
    end
  end

  def test_connection_close
    socket = TCPSocket.new("localhost", @port)

    socket.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    response = socket.read

    assert_match(/HTTP\/1\.1 200/, response)
    assert_match(/Connection: close/i, response)
    assert_match(/Hello World/, response)
    assert socket.eof?

    socket.close
  end

  def test_http_1_0
    socket = TCPSocket.new("localhost", @port)

    socket.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")

    response = socket.read

    assert_match(/HTTP\/1\.0 200/, response)
    assert_match(/Hello World/, response)
    assert socket.eof?

    socket.close
  end

end

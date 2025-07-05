# frozen_string_literal: true

require "test_helper"
require "net/http"
require "json"
require "timeout"

class TestIntegration < Minitest::Test
  TEST_PORT = 9293
  
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
    @server = Cougar::Server.new(TestApp, host: "localhost", port: TEST_PORT, workers: 2)
    @server_thread = Thread.new { @server.start }
    
    # Wait for server to start
    wait_for_server
  end
  
  def teardown
    @server&.stop
    @server_thread&.kill
    @server_thread&.join(1)
    
    # Give the OS time to release the port
    sleep 0.1
  end
  
  def test_simple_get_request
    response = Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/"))
    
    assert_equal "200", response.code
    assert_equal "Hello World", response.body
    assert_equal "text/plain", response["Content-Type"]
  end
  
  def test_json_response
    response = Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/json"))
    
    assert_equal "200", response.code
    assert_equal '{"message": "success"}', response.body
    assert_equal "application/json", response["Content-Type"]
    
    json = JSON.parse(response.body)
    assert_equal "success", json["message"]
  end
  
  def test_post_request_with_body
    uri = URI("http://localhost:#{TEST_PORT}/echo")
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
    uri = URI("http://localhost:#{TEST_PORT}/echo")
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
    uri = URI("http://localhost:#{TEST_PORT}/headers")
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
    response = Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/nonexistent"))
    
    assert_equal "404", response.code
    assert_equal "Not Found", response.body
  end
  
  def test_query_parameters
    response = Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/echo?foo=bar&baz=qux"))
    
    assert_equal "200", response.code
    assert_includes response.body, "Method: GET"
  end
  
  def test_concurrent_requests
    threads = []
    responses = []
    
    10.times do |i|
      threads << Thread.new do
        response = Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/"))
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
    
    uri = URI("http://localhost:#{TEST_PORT}/echo")
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
    uri = URI("http://localhost:#{TEST_PORT}/")
    
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
  
  private
  
  def wait_for_server
    Timeout.timeout(5) do
      loop do
        begin
          Net::HTTP.get_response(URI("http://localhost:#{TEST_PORT}/"))
          break
        rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
          sleep 0.1
        end
      end
    end
  rescue Timeout::Error
    flunk "Server failed to start within 5 seconds"
  end
end
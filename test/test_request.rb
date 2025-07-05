# frozen_string_literal: true

require "test_helper"
require "stringio"
require "socket"

class TestRequest < Minitest::Test
  def test_simple_get_request
    client = StringIO.new("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "GET", env["REQUEST_METHOD"]
    assert_equal "/", env["PATH_INFO"]
    assert_equal "", env["QUERY_STRING"]
    assert_equal "localhost", env["HTTP_HOST"]
  end

  def test_get_request_with_query_string
    client = StringIO.new("GET /path?foo=bar&baz=qux HTTP/1.1\r\nHost: example.com\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "GET", env["REQUEST_METHOD"]
    assert_equal "/path", env["PATH_INFO"]
    assert_equal "foo=bar&baz=qux", env["QUERY_STRING"]
    assert_equal "example.com", env["HTTP_HOST"]
  end

  def test_post_request_with_body
    request_data = "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"test\": \"data\"}"
    client = StringIO.new(request_data)
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "POST", env["REQUEST_METHOD"]
    assert_equal "/submit", env["PATH_INFO"]
    assert_equal "application/json", env["CONTENT_TYPE"]
    assert_equal "16", env["CONTENT_LENGTH"]
    assert_equal "{\"test\": \"data\"}", env["rack.input"].read
  end

  def test_multiple_headers
    request_data = "GET /headers HTTP/1.1\r\nHost: test.com\r\nUser-Agent: TestAgent\r\nAccept: text/html\r\nX-Custom-Header: custom-value\r\n\r\n"
    client = StringIO.new(request_data)
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "test.com", env["HTTP_HOST"]
    assert_equal "TestAgent", env["HTTP_USER_AGENT"]
    assert_equal "text/html", env["HTTP_ACCEPT"]
    assert_equal "custom-value", env["HTTP_X_CUSTOM_HEADER"]
  end

  def test_rack_environment_setup
    client = StringIO.new("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "", env["SCRIPT_NAME"]
    assert_equal "localhost", env["SERVER_NAME"]
    assert_equal "9292", env["SERVER_PORT"]
    assert_equal [1, 3], env["rack.version"]
    assert_equal "http", env["rack.url_scheme"]
    assert_equal $stderr, env["rack.errors"]
    assert_equal false, env["rack.multithread"]
    assert_equal true, env["rack.multiprocess"]
    assert_equal false, env["rack.run_once"]
    assert_kind_of StringIO, env["rack.input"]
  end

  def test_empty_body
    client = StringIO.new("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "", env["rack.input"].read
  end

  def test_put_request_with_body
    request_data = "PUT /update HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nHello World"
    client = StringIO.new(request_data)
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "PUT", env["REQUEST_METHOD"]
    assert_equal "/update", env["PATH_INFO"]
    assert_equal "text/plain", env["CONTENT_TYPE"]
    assert_equal "11", env["CONTENT_LENGTH"]
    assert_equal "Hello World", env["rack.input"].read
  end

  def test_header_case_conversion
    request_data = "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/html\r\nX-Forwarded-For: 192.168.1.1\r\n\r\n"
    client = StringIO.new(request_data)
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "localhost", env["HTTP_HOST"]
    assert_equal "text/html", env["CONTENT_TYPE"]
    assert_equal "192.168.1.1", env["HTTP_X_FORWARDED_FOR"]
  end

  def test_request_uri_parsing
    client = StringIO.new("GET /path/to/resource?param=value HTTP/1.1\r\nHost: localhost\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "/path/to/resource?param=value", env["REQUEST_URI"]
    assert_equal "/path/to/resource", env["PATH_INFO"]
    assert_equal "param=value", env["QUERY_STRING"]
  end

  def test_root_path
    client = StringIO.new("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    request = Cougar::Request.new(client)
    
    assert request.parse
    
    env = request.env
    assert_equal "/", env["REQUEST_URI"]
    assert_equal "/", env["PATH_INFO"]
    assert_equal "", env["QUERY_STRING"]
  end
end
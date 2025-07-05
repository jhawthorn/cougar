# frozen_string_literal: true

require "test_helper"

class TestRequestDelegate < Minitest::Test
  def setup
    @delegate = Cougar::RequestDelegate.new
  end
  
  def test_initialization
    assert_empty @delegate.env
    assert_equal false, @delegate.complete
  end
  
  def test_on_message_begin_resets_state
    # Set some initial state
    @delegate.env["TEST"] = "value"
    
    @delegate.on_message_begin
    
    assert_empty @delegate.env
    assert_equal false, @delegate.complete
  end
  
  def test_on_url_sets_request_uri_and_path_info
    @delegate.on_url("/path/to/resource")
    
    assert_equal "/path/to/resource", @delegate.env["REQUEST_URI"]
    assert_equal "/path/to/resource", @delegate.env["PATH_INFO"]
    assert_equal "", @delegate.env["QUERY_STRING"]
  end
  
  def test_on_url_with_query_string
    @delegate.on_url("/search?q=test&category=books")
    
    assert_equal "/search?q=test&category=books", @delegate.env["REQUEST_URI"]
    assert_equal "/search", @delegate.env["PATH_INFO"]
    assert_equal "q=test&category=books", @delegate.env["QUERY_STRING"]
  end
  
  def test_on_url_with_root_path
    @delegate.on_url("/")
    
    assert_equal "/", @delegate.env["REQUEST_URI"]
    assert_equal "/", @delegate.env["PATH_INFO"]
    assert_equal "", @delegate.env["QUERY_STRING"]
  end
  
  def test_on_url_with_empty_path
    @delegate.on_url("")
    
    assert_equal "", @delegate.env["REQUEST_URI"]
    assert_equal "/", @delegate.env["PATH_INFO"]  # Should default to "/"
    assert_equal "", @delegate.env["QUERY_STRING"]
  end
  
  def test_header_field_and_value_pairing
    @delegate.on_header_field("Content-Type")
    @delegate.on_header_value("application/json")
    
    @delegate.on_header_field("Host")
    @delegate.on_header_value("example.com")
    
    @delegate.on_headers_complete
    
    assert_equal "application/json", @delegate.env["CONTENT_TYPE"]
    assert_equal "example.com", @delegate.env["HTTP_HOST"]
  end
  
  def test_on_headers_complete_sets_rack_environment
    @delegate.on_headers_complete
    
    env = @delegate.env
    assert_equal "", env["SCRIPT_NAME"]
    assert_equal "localhost", env["SERVER_NAME"]
    assert_equal "9292", env["SERVER_PORT"]
    assert_equal [1, 3], env["rack.version"]
    assert_equal "http", env["rack.url_scheme"]
    assert_equal $stderr, env["rack.errors"]
    assert_equal false, env["rack.multithread"]
    assert_equal true, env["rack.multiprocess"]
    assert_equal false, env["rack.run_once"]
  end
  
  def test_header_conversion_to_http_format
    @delegate.on_header_field("User-Agent")
    @delegate.on_header_value("TestAgent/1.0")
    
    @delegate.on_header_field("X-Custom-Header")
    @delegate.on_header_value("custom-value")
    
    @delegate.on_headers_complete
    
    assert_equal "TestAgent/1.0", @delegate.env["HTTP_USER_AGENT"]
    assert_equal "custom-value", @delegate.env["HTTP_X_CUSTOM_HEADER"]
  end
  
  def test_special_headers_content_type_and_length
    @delegate.on_header_field("Content-Type")
    @delegate.on_header_value("text/plain")
    
    @delegate.on_header_field("Content-Length")
    @delegate.on_header_value("42")
    
    @delegate.on_headers_complete
    
    assert_equal "text/plain", @delegate.env["CONTENT_TYPE"]
    assert_equal "42", @delegate.env["CONTENT_LENGTH"]
    # Should also be available as HTTP_ headers
    assert_equal "text/plain", @delegate.env["HTTP_CONTENT_TYPE"]
    assert_equal "42", @delegate.env["HTTP_CONTENT_LENGTH"]
  end
  
  def test_on_body_accumulates_chunks
    @delegate.on_body("Hello")
    @delegate.on_body(" ")
    @delegate.on_body("World")
    
    # Body should be accumulated but not yet in env
    @delegate.on_message_complete
    
    assert_equal "Hello World", @delegate.env["rack.input"].read
  end
  
  def test_on_message_complete_sets_rack_input_and_complete_flag
    @delegate.on_body("test body")
    @delegate.on_message_complete
    
    assert_equal true, @delegate.complete
    assert_kind_of StringIO, @delegate.env["rack.input"]
    assert_equal "test body", @delegate.env["rack.input"].read
  end
  
  def test_empty_body_handling
    @delegate.on_message_complete
    
    assert_equal true, @delegate.complete
    assert_kind_of StringIO, @delegate.env["rack.input"]
    assert_equal "", @delegate.env["rack.input"].read
  end
  
  def test_multiple_requests_reset_properly
    # First request
    @delegate.on_message_begin
    @delegate.on_url("/first")
    @delegate.on_body("first body")
    @delegate.on_message_complete
    
    assert_equal "/first", @delegate.env["PATH_INFO"]
    assert_equal "first body", @delegate.env["rack.input"].read
    
    # Second request
    @delegate.on_message_begin
    @delegate.on_url("/second")
    @delegate.on_body("second body")
    @delegate.on_message_complete
    
    assert_equal "/second", @delegate.env["PATH_INFO"]
    assert_equal "second body", @delegate.env["rack.input"].read
  end
end
# frozen_string_literal: true

require "test_helper"

class TestServer < Minitest::Test
  class TestApp
    def self.call(env)
      [200, {}, ["OK"]]
    end
  end
  
  def test_server_initialization
    server = Cougar::Server.new(TestApp)
    
    assert_equal TestApp, server.app
    assert_equal "localhost", server.host
    assert_equal 9292, server.port
    assert_equal 8, server.workers  # Default from ENV.fetch("RUBY_MAX_CPU", 8)
  end
  
  def test_server_initialization_with_custom_options
    server = Cougar::Server.new(TestApp, host: "0.0.0.0", port: 3000, workers: 4)
    
    assert_equal TestApp, server.app
    assert_equal "0.0.0.0", server.host
    assert_equal 3000, server.port
    assert_equal 4, server.workers
  end
  
  def test_server_respects_ruby_max_cpu_env
    original_env = ENV["RUBY_MAX_CPU"]
    ENV["RUBY_MAX_CPU"] = "12"
    
    server = Cougar::Server.new(TestApp)
    
    assert_equal 12, server.workers
  ensure
    if original_env
      ENV["RUBY_MAX_CPU"] = original_env
    else
      ENV.delete("RUBY_MAX_CPU")
    end
  end
  
  def test_server_defaults_to_8_workers_when_env_not_set
    original_env = ENV["RUBY_MAX_CPU"]
    ENV.delete("RUBY_MAX_CPU")
    
    server = Cougar::Server.new(TestApp)
    
    assert_equal 8, server.workers
  ensure
    ENV["RUBY_MAX_CPU"] = original_env if original_env
  end
end
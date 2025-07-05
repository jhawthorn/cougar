# frozen_string_literal: true

class MyApp
  def self.call(env)
    path = env["PATH_INFO"]

    case path
    when "/"
      [200, {"Content-Type" => "text/plain"}, ["Hello from Cougar!\n"]]
    when "/json"
      [200, {"Content-Type" => "application/json"}, ['{"message": "Hello from Cougar!"}']]
    when "/headers"
      headers_info = env.select { |k, v| k.start_with?("HTTP_") }
        .map { |k, v| "#{k}: #{v}" }
        .join("\n")
      [200, {"Content-Type" => "text/plain"}, ["Request Headers:\n#{headers_info}\n"]]
    when "/echo"
      body = env["rack.input"].read
      [200, {"Content-Type" => "text/plain"}, ["Method: #{env["REQUEST_METHOD"]}\nBody: #{body}\nContent-Length: #{env["CONTENT_LENGTH"]}\n"]]
    else
      [404, {"Content-Type" => "text/plain"}, ["Not Found\n"]]
    end
  end
end

app = MyApp

run app

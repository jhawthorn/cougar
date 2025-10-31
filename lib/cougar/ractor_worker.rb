# frozen_string_literal: true

module Cougar
  class RactorWorker
    attr_reader :worker_id, :ractor

    def initialize(worker_id, server, app)
      @worker_id = worker_id
      control_port_port = Ractor::Port.new
      
      @ractor = Ractor.new(server, app, worker_id, control_port_port) do |server, app, worker_id, control_port_port|
        control_port = Ractor::Port.new
        worker_thread = Thread.current
        control_thread = Thread.new do |th|
          loop do
            case control_port.receive
            in :stop
              server.close
              break
            in [:status, response_port]
              response_port.send({
                worker_id: worker_id,
                thread_status: worker_thread.status,
                alive: worker_thread.alive?
              })
            end
          end
        end
        control_port_port.send(control_port)

        loop do
          begin
            client = server.accept
            client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          rescue IOError, Errno::EBADF => e
            # Server socket was closed, exit gracefully
            break
          end

          keepalive = true
          while keepalive
            # Create a new Request instance for this connection
            request = Cougar::Request.new(client)

            begin
              # Parse the HTTP request
              if !request.parse
                break
              end

              # Call the Rack app
              status, headers, body = app.call(request.env)

              # Send the response
              request.respond(status, headers, body)

              client.flush

              #keepalive &&= !client.closed? && !client.eof?
            rescue => e
              $stderr.puts "[Worker #{worker_id}] #{e.class}: #{e.message}"
              $stderr.puts e.backtrace
              keepalive = false
            end
          end
        ensure
          client&.close
        end

        control_thread.join
      end
      
      @control_port = control_port_port.receive
      control_port_port.close
    end

    def stop
      @control_port.send(:stop)
    end

    def send_status_request(response_port)
      @control_port.send([:status, response_port])
    end

    def join
      @ractor.join
    end
  end
end

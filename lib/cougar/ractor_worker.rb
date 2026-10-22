# frozen_string_literal: true

module Cougar
  class RactorWorker
    # Seconds a connection may sit idle, before its first request or between
    # keep-alive requests, before the worker closes it.
    KEEPALIVE_TIMEOUT = 10

    # Seconds between sweeps for idle connections, and so the longest the
    # worker will sit in select without checking for them.
    SWEEP_INTERVAL = 1

    Connection = Struct.new(:request, :last_active)

    attr_reader :worker_id, :ractor

    def initialize(worker_id, listener, app)
      @worker_id = worker_id
      control_port_port = Ractor::Port.new

      # Ruby 4.1.0dev (97207692c2) can't copy an IO into a Ractor, so each
      # worker gets its own dup'd fd.
      listener = listener.dup
      listener.autoclose = false

      @ractor = Ractor.new(listener.fileno, app, worker_id, control_port_port) do |server_fd, app, worker_id, control_port_port|
        server = TCPServer.for_fd(server_fd)
        control_port = Ractor::Port.new
        worker_thread = Thread.current

        # Closing the write end makes the read end readable, which wakes the
        # select loop below so it can shut down.
        stop_reader, stop_writer = IO.pipe

        # Every open client socket and what we know about it. Only the worker
        # thread touches this; the control thread just reads its size.
        connections = {}

        control_thread = Thread.new do
          loop do
            case control_port.receive
            in :stop
              stop_writer.close
              break
            in [:status, response_port]
              response_port.send({
                worker_id: worker_id,
                thread_status: worker_thread.status,
                alive: worker_thread.alive?,
                connections: connections.size
              })
            end
          end
        end
        control_port_port.send(control_port)

        # A single-threaded loop multiplexing every connection this worker
        # owns. Idle keep-alive connections cost nothing while they wait, so
        # a worker is never pinned to one client while others queue up in the
        # listen backlog. Requests are still handled one at a time per worker;
        # Ractors are the unit of parallelism.
        last_sweep = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stopping = false
        until stopping
          readable, = IO.select([server, stop_reader, *connections.keys], nil, nil, SWEEP_INTERVAL)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          readable&.each do |io|
            if io.equal?(stop_reader)
              stopping = true
            elsif io.equal?(server)
              # Other workers share this listener and may take some of the
              # pending connections first.
              while (client = server.accept_nonblock(exception: false)) != :wait_readable
                client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
                connections[client] = Connection.new(Cougar::Request.new(client), now)
              end
            else
              connection = connections[io]
              if RactorWorker.handle_readable(io, connection.request, app, worker_id)
                connection.last_active = now
              else
                connections.delete(io)
                io.close
              end
            end
          end

          if now - last_sweep >= SWEEP_INTERVAL
            last_sweep = now
            connections.delete_if do |client, connection|
              if now - connection.last_active >= KEEPALIVE_TIMEOUT
                client.close
                true
              end
            end
          end
        end

        connections.each_key(&:close)
        server.close
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

    # Called when the client socket is readable. Serves every complete request
    # already buffered, without blocking for more. Returns true if the
    # connection should stay open.
    def self.handle_readable(client, request, app, worker_id)
      loop do
        case request.parse
        when false
          # Client disconnected
          return false
        when :wait_readable
          # Partial request; come back when the rest arrives.
          return true
        end

        # Call the Rack app
        status, headers, body = app.call(request.env)

        # Send the response
        return false unless request.respond(status, headers, body)

        request.reset_for_next_request

        # Keep going only if a pipelined request is already buffered.
        return true unless request.has_buffered_data?
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Cougar::Request::TimeoutError
      # The client went away or was too slow to take the response.
      false
    rescue => e
      $stderr.puts "[Worker #{worker_id}] #{e.class}: #{e.message}"
      $stderr.puts e.backtrace
      false
    end
  end
end

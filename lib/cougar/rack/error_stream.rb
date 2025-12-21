# frozen_string_literal: true

module Cougar
  module Rack
    class ErrorStream
      def puts(*args)
        $stderr.puts(*args)
      end

      def write(*args)
        $stderr.write(*args)
      end

      def flush
        $stderr.flush
      end
    end

    ERROR_STREAM = ErrorStream.new.freeze
  end
end

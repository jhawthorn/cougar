# frozen_string_literal: true

module Cougar
  module Rack
    class EmptyInput
      def gets
        nil
      end

      def read(length = nil, buffer = nil)
        buffer&.clear
        if length
          nil
        else
          buffer || ""
        end
      end

      def each
      end

      def close
      end
    end

    EMPTY_INPUT = EmptyInput.new.freeze
  end
end

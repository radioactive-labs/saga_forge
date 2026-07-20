module SagaForge
  module Dashboard
    class ContextPresenter
      Node = Struct.new(:key, :type, :bytes, :preview)

      # Above this many elements, a Hash/Array value isn't fully serialized
      # just to build a 200-char preview; only its size is reported. Guards
      # against a single giant context value (e.g. a batch job's collected
      # results) doing an unbounded JSON serialization on every page load.
      LARGE_COLLECTION_THRESHOLD = 50

      def initialize(state)
        @context = state.context || {}
      end

      def user_nodes
        @user_nodes ||= @context.except("__saga_forge").map { |k, v| node(k, v) }
      end

      def saga_meta = @context["__saga_forge"] # nil or the reserved sub-hash

      private

      def node(key, value)
        type = ruby_type(value)
        if large_collection?(value)
          Node.new(key: key, type: type, bytes: nil, preview: "(#{type}, #{value.size} entries, too large to preview)")
        else
          json = value.to_json
          Node.new(key: key, type: type, bytes: json.bytesize, preview: json.truncate(200))
        end
      end

      def large_collection?(v)
        (v.is_a?(Hash) || v.is_a?(Array)) && v.size > LARGE_COLLECTION_THRESHOLD
      end

      def ruby_type(v)
        case v
        when Hash then "object"
        when Array then "array"
        when Numeric then "number"
        when TrueClass, FalseClass then "boolean"
        when NilClass then "null"
        else "string"
        end
      end
    end
  end
end

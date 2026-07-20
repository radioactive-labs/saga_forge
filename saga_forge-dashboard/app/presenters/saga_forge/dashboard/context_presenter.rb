module SagaForge
  module Dashboard
    class ContextPresenter
      Node = Struct.new(:key, :type, :bytes, :preview)

      def initialize(state)
        @context = state.context || {}
      end

      def user_nodes
        @context.except("__saga_forge").map { |k, v| node(k, v) }
      end

      def saga_meta = @context["__saga_forge"] # nil or the reserved sub-hash

      private

      def node(key, value)
        json = value.to_json
        Node.new(key: key, type: ruby_type(value), bytes: json.bytesize, preview: json.truncate(200))
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

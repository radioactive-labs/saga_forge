module SagaForge
  module Execution
    # Yielded to compensation blocks: context is the snapshot (§A.4).
    # No transition verbs — rollback has one direction.
    class CompensationFacade
      attr_reader :correlation_id, :current_state, :context, :staged_publishes

      def initialize(correlation_id:, current_state:, context:, id_prefix:)
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @id_prefix = id_prefix
        @staged_publishes = []
        @publish_seq = 0
      end

      def publish(event_name, **payload)
        rows = Router.resolve(event_name, payload)
        seq = (@publish_seq += 1)
        rows.each { |attrs| @staged_publishes << attrs.merge(event_id: "#{@id_prefix}:#{seq}") }
        nil
      end
    end
  end
end

module SagaForge
  module Execution
    # Yielded to compensation blocks: context is the snapshot (§A.4).
    # No transition verbs — rollback has one direction.
    class CompensationFacade
      attr_reader :correlation_id, :current_state, :context, :staged_publishes

      def initialize(correlation_id:, current_state:, context:)
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @staged_publishes = []
      end

      def publish(event_name, **payload)
        @staged_publishes.concat(Router.resolve(event_name, payload))
        nil
      end
    end
  end
end

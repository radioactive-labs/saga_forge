module SagaForge
  module Execution
    # The `saga` object yielded to forward blocks (§A.1 verbs). Everything is
    # staged in memory; the Runner commits it.
    class Facade
      # Verb semantics: last verb call wins — calling transition_to twice, or
      # stay then transition_to, simply overwrites @outcome with whatever ran
      # last, and the block keeps executing. fail! is the one exception: it
      # both records its outcome AND throws :saga_forge_fail, short-
      # circuiting the rest of the block immediately. Every other verb is
      # just a plain method call with no control-flow effect.
      attr_reader :correlation_id, :current_state, :context, :outcome, :staged_publishes

      def initialize(definition:, correlation_id:, current_state:, context:, source_event_id:)
        @definition = definition
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @source_event_id = source_event_id
        @staged_publishes = []
        @outcome = nil
      end

      def transition_to(state)
        unless @definition.declared?(state)
          raise UnknownStateError, "transition_to #{state.inspect} — undeclared state"
        end
        @outcome = [:transition_to, state.to_sym]
        nil
      end

      def stay
        if @current_state == Definition::START
          raise Error, "stay is not valid in start_with — there is no start state to remain in"
        end
        @outcome = :stay
        nil
      end

      def fail!(reason: nil)
        @outcome = [:fail, reason]
        throw :saga_forge_fail
      end

      # Staged publish (§A.2): resolve recipients NOW (call-site stack trace,
      # MissingCorrelationError surfaces under the block's retry policy),
      # hold fully-built rows; the Runner inserts them inside its commit.
      def publish(event_name, **payload)
        rows = Router.resolve(event_name, payload)
        seq = @publish_seq = (@publish_seq || 0) + 1
        rows.each do |attrs|
          @staged_publishes << attrs.merge(event_id: "staged:#{@source_event_id}:#{seq}")
        end
        nil
      end
    end
  end
end

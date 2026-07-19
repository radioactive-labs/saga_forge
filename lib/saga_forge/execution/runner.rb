module SagaForge
  module Execution
    # Processes one pending ledger row through the §A.4 pipeline.
    # Returns [:done] | [:respin] | [:retry, seconds].
    class Runner
      attr_reader :event

      def initialize(event)
        @event = event
      end

      def call
        return [:done] unless event.pending?
        return [:done] if halted?

        saga_class = event.saga_class.constantize
        definition = saga_class.definition
        state_row = State.find_by(saga_class: event.saga_class, correlation_id: event.correlation_id)
        current = state_row&.current_state&.to_sym || Definition::START

        return discard_terminal!(current) if definition.terminal?(current)

        expected = definition.state_for_event(event.event_name)
        return stall! if expected != current

        execute!(definition, state_row, current)
      end

      private

      # Poison-pill halt (§A.3): derived from the ledger at job entry.
      def halted?
        Event.failed.for_instance(event.saga_class, event.correlation_id).exists?
      end

      # Atomic increment (not read-modify-write): concurrent deliveries outside
      # Solid Queue's serialization must not lose updates (§A.3 — correctness
      # never depends on the concurrency-limit nicety).
      def stall!
        Event.where(id: event.id).update_all("stall_count = stall_count + 1")
        count = event.reload.stall_count
        if count >= SagaForge.config.stall_budget
          event.update!(status: :stalled)
          [:done]
        else
          [:respin]
        end
      end

      def discard_terminal!(current)
        event.update!(status: :processed, error: {"discarded" => "terminal state #{current}"})
        Rails.logger.info { "[saga_forge] discarded #{event.event_name} for terminal #{event.saga_class}##{event.correlation_id}" }
        [:done]
      end

      def execute!(definition, state_row, current)
        raise NotImplementedError, "Task 6 implements block execution and the commit"
      end
    end
  end
end

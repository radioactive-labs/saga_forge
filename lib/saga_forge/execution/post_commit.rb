module SagaForge
  module Execution
    # Shared post-commit effects (§A.1 arming, §A.3 re-delivery): entering
    # (or staying in) a state re-delivers any events parked for it and arms
    # its timeout-declaring handlers. Both Runner (after a normal commit) and
    # TimeoutJob (after a live timeout branch transition) land here — neither
    # needs anything but (definition, state): saga_class/correlation_id/
    # current_state/version/id off the state row.
    module PostCommit
      def redeliver_parked(definition, state)
        names = definition.events_for_state(state.current_state).map(&:to_s)
        return if names.empty?
        Event.stalled.for_instance(state.saga_class, state.correlation_id)
          .where(event_name: names).ledger_order.each do |parked|
          parked.update!(status: :pending, stall_count: 0)
          ExecutionJob.perform_later(parked.id)
        end
      end

      def arm_timeouts(definition, state)
        current = state.current_state.to_sym
        definition.events_for_state(current).each do |event_name|
          handler = definition.handler_for(event_name)
          next unless handler.timeout
          TimeoutJob.set(wait: handler.timeout)
            .perform_later(state.id, event_name.to_s, state.version)
        end
      end
    end
  end
end

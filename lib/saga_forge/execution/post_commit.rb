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
          # Status-scoped: only flip rows still :stalled. A racing commit
          # (another redeliver_parked, or this same row processed in the
          # meantime) can move a row to :processed between the SELECT above
          # and this write — the scope makes that race lose cleanly instead
          # of regressing a committed row back to :pending.
          updated = Event.where(id: parked.id, status: :stalled)
            .update_all(status: :pending, stall_count: 0, updated_at: Time.current)
          ExecutionJob.perform_later(parked.id) if updated > 0
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

      # Forward-only: a saga never re-enters a state it has resided in, so it
      # handles each event name at most once (the invariant structural dedup
      # relies on). Visited = every processed event's registered state, plus
      # the current state. Covers fall-through, transition_to, AND timeout
      # branches. Raises ForwardOnlyError on a re-entry.
      def guard_forward_only!(definition, saga_class, correlation_id, current, next_state)
        visited = Event.processed
          .for_instance(saga_class, correlation_id)
          .pluck(:event_name)
          .filter_map { |name| definition.state_for_event(name)&.to_s }
        visited << current.to_s
        return unless visited.include?(next_state)
        raise ForwardOnlyError,
          "#{saga_class}##{correlation_id}: advance to #{next_state} re-enters a visited state — sagas are forward-only"
      end
    end
  end
end

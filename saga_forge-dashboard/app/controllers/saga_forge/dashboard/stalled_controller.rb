module SagaForge
  module Dashboard
    # Instances (across every saga class) with at least one event parked in
    # :stalled — it exhausted its retry budget and is waiting to be retried.
    class StalledController < BaseController
      # Bound the scan: at scale there can be a large backlog, so we examine
      # at most CAP (most recently updated first) rather than the whole table.
      CAP = 500

      def index
        @states = SagaForge::State.stalled.order(updated_at: :desc).limit(CAP).to_a
        @capped = @states.size == CAP

        # Single batched query keyed by saga_forge_state_id, grouped in Ruby,
        # instead of one query per row (N+1 at CAP=500 rows).
        @event_names = SagaForge::Event.stalled
          .where(saga_forge_state_id: @states.map(&:id))
          .ledger_order
          .pluck(:saga_forge_state_id, :event_name)
          .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(id, name), acc| acc[id] << name }
      end
    end
  end
end

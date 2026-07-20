module SagaForge
  module Dashboard
    # Instances (across every saga class) with at least one event that ran out
    # of retries and landed in :failed — the saga is suspended pending a
    # resume or compensate decision.
    class SuspendedController < BaseController
      # Bound the scan: at scale there can be a large backlog, so we examine
      # at most CAP (most recently updated first) rather than the whole table.
      CAP = 500

      def index
        @states = SagaForge::State.suspended.order(updated_at: :desc).limit(CAP).to_a
        @capped = @states.size == CAP

        # Single batched query keyed by saga_forge_state_id, grouped in Ruby,
        # instead of one query per row (N+1 at CAP=500 rows). A state can have
        # more than one failed event; earliest (ledger order) wins as "the"
        # failure to show.
        failed = SagaForge::Event.failed
          .where(saga_forge_state_id: @states.map(&:id))
          .select(:saga_forge_state_id, :event_name, :error, :created_at, :id)
          .ledger_order
          .to_a
        @failed_event = failed.group_by(&:saga_forge_state_id).transform_values(&:first)
      end
    end
  end
end

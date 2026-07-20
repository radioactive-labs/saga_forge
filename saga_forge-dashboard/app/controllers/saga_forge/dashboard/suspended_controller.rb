module SagaForge
  module Dashboard
    # Instances (across every saga class) with at least one event that ran out
    # of retries and landed in :failed — the saga is suspended pending a
    # resume or compensate decision.
    class SuspendedController < BaseController
      # Bound the scan: at scale there can be a large backlog, so we examine
      # at most CAP (most recently updated first), like chrono's
      # stranded/wait-state triage pages.
      CAP = 500

      def index
        @states = SagaForge::State.suspended.order(updated_at: :desc).limit(CAP).to_a
        @capped = @states.size == CAP

        # Batch the failed events for the whole page in one query instead of
        # one per row (N+1 at CAP=500 rows) — same pattern as chrono's
        # WaitStatePresenter.active_map. A state can have more than one failed
        # event; earliest (ledger order) wins as "the" failure to show.
        failed = SagaForge::Event.failed
          .where(saga_forge_state_id: @states.map(&:id))
          .select(:saga_forge_state_id, :event_name, :error, :created_at, :id)
          .order(:created_at, :id)
          .to_a
        @failed_event = failed.group_by(&:saga_forge_state_id).transform_values(&:first)
      end
    end
  end
end

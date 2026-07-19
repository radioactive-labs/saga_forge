module SagaForge
  # Prunes processed events past retention — but only for sagas already in a
  # terminal state: active sagas derive compensation from their history (§A.6).
  class RetentionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    # See ExecutionJob::CONCURRENCY_KEY for why this is a constant.
    CONCURRENCY_KEY = "SagaForge::Retention"

    if defined?(SolidQueue)
      limits_concurrency key: CONCURRENCY_KEY
    end

    BATCH_SIZE = 500

    def perform
      cutoff = SagaForge.config.retention.ago
      prunable_ids = []

      Event.processed.where(created_at: ..cutoff).find_each do |event|
        state = event.state
        # No state row: an orphaned discard note deriving nothing — always
        # prunable once aged. Otherwise prune only once the saga is terminal.
        next unless state.nil? || state.saga_class.safe_constantize&.definition&.terminal?(state.current_state)

        prunable_ids << event.id
        if prunable_ids.size >= BATCH_SIZE
          Event.where(id: prunable_ids).delete_all
          prunable_ids.clear
        end
      end

      Event.where(id: prunable_ids).delete_all if prunable_ids.any?
    end
  end
end

module SagaForge
  # Prunes processed events past retention — but only for sagas already
  # finalized: active sagas derive compensation from their history (§A.6).
  # Finalized-ness is the persisted saga_forge_states.finalized_at, stamped
  # atomically at commit (no constantize — robust to a since-deleted saga
  # class, which used to leak those rows past retention forever).
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
      scope = Event.processed.where(last_processed_at: ..cutoff)
        .left_joins(:state)
        .where("saga_forge_states.id IS NULL OR saga_forge_states.finalized_at IS NOT NULL")

      scope.in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
    end
  end
end

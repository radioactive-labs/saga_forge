module SagaForge
  # Prunes processed events past retention — but only for sagas already in a
  # terminal state: active sagas derive compensation from their history (§A.6).
  class RetentionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform
      cutoff = SagaForge.config.retention.ago
      Event.processed.where(created_at: ..cutoff).find_each do |event|
        state = event.state
        if state.nil?
          event.destroy! # orphaned discard notes derive nothing
          next
        end
        definition = state.saga_class.safe_constantize&.definition
        next unless definition
        event.destroy! if definition.terminal?(state.current_state)
      end
    end
  end
end

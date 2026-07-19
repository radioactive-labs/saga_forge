module SagaForge
  # Placeholder — real compensation execution lands in Task 8.
  class CompensationJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(state_id)
    end
  end
end

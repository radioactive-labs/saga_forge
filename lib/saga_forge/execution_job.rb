module SagaForge
  class ExecutionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(event_row_id)
      # Tasks 5/6 implement the pipeline.
    end
  end
end

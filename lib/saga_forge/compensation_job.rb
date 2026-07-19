module SagaForge
  class CompensationJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    # See ExecutionJob::CONCURRENCY_KEY for why this is a constant.
    CONCURRENCY_KEY = ->(state_id) {
      state = State.find_by(id: state_id)
      state ? "SagaLock:#{state.saga_class}:#{state.correlation_id}" : "SagaLock:none"
    }

    if defined?(SolidQueue)
      limits_concurrency key: CONCURRENCY_KEY
    end

    def perform(state_id)
      state = State.find_by(id: state_id)
      return unless state
      return unless state.current_state == State::COMPENSATING.to_s

      outcome, wait = CompensationRunner.new(state).call
      retry_job(wait: wait) if outcome == :retry
    end
  end
end

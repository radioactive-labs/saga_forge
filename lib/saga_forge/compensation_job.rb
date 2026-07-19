module SagaForge
  class CompensationJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(state_id)
      state = State.find_by(id: state_id)
      return unless state
      return unless state.current_state == State::COMPENSATING.to_s

      outcome, wait = CompensationRunner.new(state).call
      retry_job(wait: wait) if outcome == :retry
    end
  end
end

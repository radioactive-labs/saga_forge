module SagaForge
  # One job per ledger row; the row id is the only argument (§A.4).
  class ExecutionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    NOT_FOUND_RETRIES = 5
    NOT_FOUND_WAIT = 2.seconds

    # Extracted to a constant (rather than inlined into the limits_concurrency
    # call) so it's unit-testable without Solid Queue loaded: declaring
    # limits_concurrency is inert without the adapter active (it just sets
    # class_attributes — see ActiveJob::ConcurrencyControls), but *loading*
    # Solid Queue this late (after Combustion has already booted the test
    # app) doesn't retroactively install its ActiveJob extension. See
    # test/concurrency_controls_test.rb.
    CONCURRENCY_KEY = ->(event_row_id) {
      event = Event.find_by(id: event_row_id)
      event ? "SagaLock:#{event.saga_class}:#{event.correlation_id}" : "SagaLock:none"
    }

    if defined?(SolidQueue)
      limits_concurrency key: CONCURRENCY_KEY
    end

    def perform(event_row_id)
      event = Event.find_by(id: event_row_id)
      unless event
        # Pre-commit race from an external publish inside a caller's
        # transaction: brief bounded retry, then silent discard (§A.2).
        retry_job(wait: NOT_FOUND_WAIT) if executions < NOT_FOUND_RETRIES
        return
      end

      outcome, arg = Execution::Runner.new(event).call
      case outcome
      when :respin then retry_job(wait: SagaForge.config.stall_wait)
      when :retry then retry_job(wait: arg)
      end
    end
  end
end

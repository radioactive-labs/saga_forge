module SagaForge
  module Dashboard
    # Fans out per-instance retry/resume off the request thread. The "Retry
    # all stalled" / "Resume all suspended" buttons enqueue one of these
    # instead of looping in the controller, so the HTTP request stays fast
    # even when thousands of instances are eligible.
    #
    # Idempotent like the per-instance operator methods it calls: both
    # retry_stalled! and resume! are status-scoped no-ops when there's
    # nothing eligible on a given instance, so a duplicate enqueue (or a race
    # with a per-instance retry) is harmless.
    class BulkRecoveryJob < ActiveJob::Base
      def perform(saga_class, mode)
        scope = SagaForge::State.for_saga(saga_class)
        scope = (mode == "resume") ? scope.suspended : scope.stalled
        scope.find_each { |state| (mode == "resume") ? state.resume! : state.retry_stalled! }
      end
    end
  end
end

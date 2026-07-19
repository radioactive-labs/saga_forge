# Throwaway fixture: a plain (non-composite) retry policy, to assert that
# retry_budgets is never written when the resolved policy isn't a composite.
class PlainRetrySaga < SagaForge::Base
  correlate_by :id
  retry_policy max_attempts: 2
  start_with(:plain_started) { |saga, _payload| raise "always fails" }
  finish_with :plain_done
end

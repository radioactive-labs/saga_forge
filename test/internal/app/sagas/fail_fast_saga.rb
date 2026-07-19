class FailFastSaga < SagaForge::Base
  correlate_by :id
  start_with(:doomed) { |saga, _payload| saga.fail! reason: "no" }
  finish_with :never
end

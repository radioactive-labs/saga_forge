class SelfLoopSaga < SagaForge::Base
  correlate_by :id
  start_with(:sl_started) { |saga, _payload| }
  during(:spin, on: :again) { |saga, _payload| saga.transition_to(:spin) } # illegal: spin is current state
  finish_with :sl_done
end

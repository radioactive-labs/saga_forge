class BackwardSaga < SagaForge::Base
  correlate_by :id
  start_with(:bw_started) { |saga, _payload| }
  during(:step_a, on: :go_a) { |saga, _payload| }
  during(:step_b, on: :go_b) { |saga, _payload| saga.transition_to(:step_a) } # illegal: step_a already visited
  finish_with :bw_done
end

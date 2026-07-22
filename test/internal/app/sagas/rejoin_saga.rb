class RejoinSaga < SagaForge::Base
  correlate_by :id
  start_with(:rj_started) { |saga, _payload| }
  during(:branch_point, on: :decide) do |saga, payload|
    saga.transition_to(:detour) if payload[:take_detour]
  end
  during(:mainline, on: :proceed) { |saga, _payload| }
  during(:detour, on: :detour_done) { |saga, _payload| saga.transition_to(:mainline) } # legal: mainline not yet visited
  finish_with :rj_done
end

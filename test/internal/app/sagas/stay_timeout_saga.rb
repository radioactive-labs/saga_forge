class StayTimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:st_started) { |saga, _payload| }
  during(:st_looping, on: :st_tick, timeout: 10.minutes, on_timeout: :fail!) do |saga, _payload|
    saga.stay
  end
  finish_with :st_done
end

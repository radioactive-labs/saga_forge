class StayTimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:st_started) { |saga, _payload| }
  during(:st_waiting, on: :st_tick, timeout: 10.minutes, on_timeout: :fail!) { |saga, _payload| }
  finish_with :st_done
end

class BackwardTimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:bt_started) { |saga, _payload| }
  during(:bt_a, on: :bt_go) { |saga, _payload| }
  during(:bt_b, on: :bt_never, timeout: 5.minutes, on_timeout: :bt_a) { |saga, _payload| }
  finish_with :bt_done
end

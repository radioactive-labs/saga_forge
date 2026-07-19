class TimeoutBranchSaga < SagaForge::Base
  correlate_by :id
  start_with(:tb_started) { |saga, _payload| }
  during(:waiting_fast, on: :tb_fast, timeout: 5.minutes, on_timeout: :waiting_slow) { |saga, _payload| }
  during(:waiting_slow, on: :tb_slow) { |saga, _payload| }
  finish_with :tb_finished
end

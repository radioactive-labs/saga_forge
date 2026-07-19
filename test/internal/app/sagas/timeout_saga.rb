class TimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:t_started, compensate: :t_undo) { |saga, _payload| saga.context[:started] = true }
  during(:waiting, on: :t_arrived, timeout: 30.minutes, on_timeout: :fail!) { |saga, _payload| }
  finish_with :t_done
  compensation(:t_undo) { |saga| saga.context[:undone] = true }
end

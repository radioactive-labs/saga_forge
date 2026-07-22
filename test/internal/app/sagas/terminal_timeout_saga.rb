class TerminalTimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:tt_started) { |saga, _payload| }
  during(:tt_waiting, on: :tt_never, timeout: 5.minutes, on_timeout: :tt_done) { |saga, _payload| }
  finish_with :tt_done
end

class BrokenCompSaga < SagaForge::Base
  correlate_by :id
  start_with(:broken_started, compensate: :explode) { |saga, _payload| saga.context[:started] = true }
  during(:running, on: :broken_go) { |saga, _payload| saga.fail! reason: "go" }
  finish_with :broken_done
  compensation(:explode) { |_saga| raise "compensation bug" }
end

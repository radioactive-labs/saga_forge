class DemoSaga < SagaForge::Base
  correlate_by :id
  start_with(:demo_started) { |saga, _| saga.context[:started] = true }
  during(:demo_waiting, on: :demo_done) { |saga, _| }
  finish_with :demo_complete
end

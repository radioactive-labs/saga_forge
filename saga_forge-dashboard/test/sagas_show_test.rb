require "test_helper"

class SagasShowTest < SagaForge::Dashboard::TestCase
  test "show renders timeline and flags suspended" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(saga_class: "DemoSaga", correlation_id: "c1",
      event_name: "demo_done", status: :failed, state: s, error: {"class" => "Boom", "message" => "nope"})
    get "/saga_forge/sagas/#{s.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "demo_done"
    assert_includes last_response.body, "Boom"
  end

  test "compensate is offered while active, hidden once finalized_at is set" do
    active = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "demo_waiting")
    get "/saga_forge/sagas/#{active.id}"
    assert_includes last_response.body, "Compensate"

    finalized = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c3", current_state: "demo_complete",
      finalized_at: Time.current)
    get "/saga_forge/sagas/#{finalized.id}"
    refute_includes last_response.body, "Compensate"
  end
end

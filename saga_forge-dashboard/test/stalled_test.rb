require "test_helper"

class StalledTest < SagaForge::Dashboard::TestCase
  test "lists instances with a stalled event and shows the parked event name" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "s1", current_state: "demo_waiting")
    SagaForge::Event.create!(saga_class: "DemoSaga", correlation_id: "s1",
      event_name: "demo_done", status: :stalled, state: s)
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "clean", current_state: "demo_waiting")

    get "/saga_forge/stalled"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "s1"
    assert_includes last_response.body, "demo_done"
    refute_includes last_response.body, ">clean<"
  end

  test "empty state renders when nothing is stalled" do
    get "/saga_forge/stalled"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "No stalled sagas"
  end
end

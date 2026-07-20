require "test_helper"

class SuspendedTest < SagaForge::Dashboard::TestCase
  test "lists instances with a failed event and shows the error class/message" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "s1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "s1",
      event_name: "demo_done", status: :failed, state: s, error: {"class" => "Boom", "message" => "nope"})
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "clean", current_state: "demo_waiting")

    get "/saga_forge/suspended"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "s1"
    assert_includes last_response.body, "Boom"
    assert_includes last_response.body, "nope"
    refute_includes last_response.body, ">clean<"
  end

  test "empty state renders when nothing is suspended" do
    get "/saga_forge/suspended"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "No suspended sagas"
  end
end

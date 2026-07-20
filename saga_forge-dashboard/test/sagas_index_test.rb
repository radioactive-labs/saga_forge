require "test_helper"

class SagasIndexTest < SagaForge::Dashboard::TestCase
  test "index renders rows for the selected class" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "shown", current_state: "demo_waiting")
    get "/saga_forge/sagas", {class: "DemoSaga"}
    assert_equal 200, last_response.status
    assert_includes last_response.body, "shown"
  end
end

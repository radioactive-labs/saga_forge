require "test_helper"

class OverviewTest < SagaForge::Dashboard::TestCase
  test "index renders the card shell and lazy-loading classes frame" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "shown", current_state: "demo_waiting")
    get "/saga_forge/overview"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Overview"
    assert_includes last_response.body, 'src="/saga_forge/overview/classes"'
    assert_includes last_response.body, 'loading="lazy"'
  end

  test "classes frame renders the per-class breakdown without the layout" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "shown", current_state: "demo_waiting")
    get "/saga_forge/overview/classes"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "DemoSaga"
    assert_includes last_response.body, "demo_waiting"
    refute_includes last_response.body, "<html"
  end
end

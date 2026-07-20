require "test_helper"

class DefinitionsControllerTest < SagaForge::Dashboard::TestCase
  test "renders graph data attribute" do
    get "/saga_forge/definitions/OrderSaga"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "data-graph"
    assert_includes last_response.body, "saga_graph.js"
  end

  test "unknown class is a friendly empty state" do
    get "/saga_forge/definitions/NopeSaga"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "NopeSaga"
    refute_includes last_response.body, "data-graph"
  end

  test "correlation_id overlays the matching instance onto the graph" do
    SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "abc", current_state: "awaiting_settlement")
    get "/saga_forge/definitions/OrderSaga", {correlation_id: "abc"}
    assert_equal 200, last_response.status
    assert_includes last_response.body, "status-active"
  end

  test "an unmatched correlation_id renders the bare class graph, not a 500" do
    get "/saga_forge/definitions/OrderSaga", {correlation_id: "does-not-exist"}
    assert_equal 200, last_response.status
    assert_includes last_response.body, "data-graph"
  end
end

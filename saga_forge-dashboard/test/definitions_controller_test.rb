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

  # No namespaced saga fixture exists in the dummy app (adding one just for
  # this route check would mean registering a throwaway class into the
  # global Router for the rest of the process, per definition_graph_test.rb's
  # comment in the core gem about that hazard). Instead, verify the route
  # itself recognizes a "::"-containing class param end to end — the
  # constraint (/[\w:]+/) exists specifically for Foo::BarSaga-shaped names.
  test "the route recognizes a ::-containing class param" do
    route = Rails.application.routes.recognize_path("/saga_forge/definitions/Foo::BarSaga", method: :get)
    assert_equal "saga_forge/dashboard/definitions", route[:controller]
    assert_equal "show", route[:action]
    assert_equal "Foo::BarSaga", route[:class]
  end
end

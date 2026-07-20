require "test_helper"

class SagaGraphTest < SagaForge::Dashboard::TestCase
  test "elements carry kind and status classes" do
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d).to_h
    assert h[:nodes].any? { |n| n[:classes].include?("kind-terminal") }
    assert h[:nodes].any? { |n| n[:classes].include?("kind-start") }
    assert h[:nodes].all? { |n| n[:classes].include?("status-none") }
    assert h[:edges].any? { |e| e[:classes].include?("kind-chain") }
    assert h[:edges].any? { |e| e[:classes].include?("kind-jump") }
    assert h[:edges].any? { |e| e[:classes].include?("kind-stay") }
  end

  test "overlay marks current state active" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "1", current_state: "awaiting_settlement")
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    active = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    assert_includes active[:classes], "status-active"
  end

  test "overlay resolves an event's node via state_for_event (not edge-label scanning)" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "2", current_state: "awaiting_review")
    SagaForge::Event.create!(event_id: "e1", saga_class: "OrderSaga", correlation_id: "2",
      event_name: "payment_settled", status: :processed, state: s)
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    settled_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    assert_includes settled_node[:classes], "status-processed"
  end

  test "overlay colors a state by the worst of its events' statuses" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "3", current_state: "awaiting_review")
    SagaForge::Event.create!(event_id: "e1", saga_class: "OrderSaga", correlation_id: "3",
      event_name: "payment_settled", status: :processed, state: s)
    SagaForge::Event.create!(event_id: "e2", saga_class: "OrderSaga", correlation_id: "3",
      event_name: "payment_failed", status: :failed, state: s)
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    settled_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    assert_includes settled_node[:classes], "status-failed"
  end

  test "a state with no events defaults to status-none" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "4", current_state: "awaiting_review")
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    completed_node = h[:nodes].find { |n| n[:data][:id] == "completed" }
    assert_includes completed_node[:classes], "status-none"
  end

  test "two nodes each get their own worst-status without cross-contamination" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "5", current_state: "completed")
    # payment_settled resolves to awaiting_settlement; review_passed resolves
    # to awaiting_review — two distinct nodes, given deliberately opposite
    # statuses so a regression to a single scalar "worst status" (instead of
    # a per-node map) would show up as either node bleeding the other's color.
    SagaForge::Event.create!(event_id: "e1", saga_class: "OrderSaga", correlation_id: "5",
      event_name: "payment_settled", status: :processed, state: s)
    SagaForge::Event.create!(event_id: "e2", saga_class: "OrderSaga", correlation_id: "5",
      event_name: "review_passed", status: :failed, state: s)
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    settlement_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    review_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_review" }
    assert_includes settlement_node[:classes], "status-processed"
    refute_includes settlement_node[:classes], "status-failed"
    assert_includes review_node[:classes], "status-failed"
    refute_includes review_node[:classes], "status-processed"
  end

  test "an event whose name doesn't resolve via state_for_event is skipped, not raised" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "6", current_state: "awaiting_settlement")
    # No handler declares this event; Definition#state_for_event returns nil
    # for it, exercising the `next unless node` guard in SagaGraph.
    SagaForge::Event.create!(event_id: "e1", saga_class: "OrderSaga", correlation_id: "6",
      event_name: "totally_bogus_event", status: :failed, state: s)
    d = OrderSaga.definition
    h = nil
    assert_nothing_raised { h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h }
    active_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    review_node = h[:nodes].find { |n| n[:data][:id] == "awaiting_review" }
    completed_node = h[:nodes].find { |n| n[:data][:id] == "completed" }
    # The current state still wins as active — the unresolvable event's
    # :failed status never lands anywhere.
    assert_includes active_node[:classes], "status-active"
    refute_includes active_node[:classes], "status-failed"
    assert_includes review_node[:classes], "status-none"
    assert_includes completed_node[:classes], "status-none"
  end
end

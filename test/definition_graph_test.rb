require "test_helper"

class DefinitionGraphTest < SagaForge::TestCase
  test "to_graph nodes: start, during states, terminals" do
    g = OrderSaga.definition.to_graph
    kinds = g.nodes.group_by(&:kind).transform_values { |ns| ns.map(&:id) }
    assert_equal ["__start__"], kinds[:start]
    assert_includes kinds[:state], "awaiting_settlement"
    assert_includes kinds[:terminal], "completed"
  end

  test "chain edges are complete and labeled by event" do
    g = OrderSaga.definition.to_graph
    chain = g.edges.select { |e| e.kind == :chain }
    pairs = chain.map { |e| [e.from, e.to] }
    assert_includes pairs, ["__start__", "awaiting_settlement"]
    assert_includes pairs, ["awaiting_settlement", "awaiting_review"]
    settle = chain.find { |e| e.from == "awaiting_settlement" }
    assert_includes settle.label, "payment_settled"
  end

  test "jump edges match jump_targets" do
    g = OrderSaga.definition.to_graph
    jumps = g.edges.select { |e| e.kind == :jump }.map { |e| [e.from, e.to] }
    # OrderSaga's review_passed handler does `transition_to :completed`
    assert_includes jumps, ["awaiting_review", "completed"]
  end

  test "stay self-loop detected" do
    # StaySaga (existing fixture) loops in :counting on :tick
    g = StaySaga.definition.to_graph
    stays = g.edges.select { |e| e.kind == :stay }.map { |e| [e.from, e.to] }
    assert_includes stays, ["counting", "counting"]
  end

  test "graph and members are frozen and serialize to_h" do
    g = OrderSaga.definition.to_graph
    assert g.frozen?
    assert g.nodes.frozen?
    assert g.edges.frozen?
    h = g.to_h
    assert h[:nodes].first.key?(:kind)
    assert h[:edges].first.key?(:label)
  end
end

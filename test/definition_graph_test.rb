require "test_helper"

class DefinitionGraphTest < SagaForge::TestCase
  # The multi-terminal test below defines a throwaway Class.new(SagaForge::Base)
  # fixture purely to exercise to_graph. Base.inherited registers every one of
  # them into the global Router, which would otherwise permanently pollute it
  # for the rest of the test process. Snapshot/restore around each test
  # (mirrors DefinitionTest's pattern).
  setup { @router_snapshot = SagaForge::Router.saga_classes.dup }
  teardown { SagaForge::Router.instance_variable_set(:@classes, @router_snapshot) }

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

  test "graph and members are frozen and serialize to_h" do
    g = OrderSaga.definition.to_graph
    assert g.frozen?
    assert g.nodes.frozen?
    assert g.edges.frozen?
    assert g.nodes.first.frozen?
    assert g.edges.first.frozen?
    h = g.to_h
    assert h[:nodes].first.key?(:kind)
    assert h[:edges].first.key?(:label)
  end

  test "a second terminal reached by a literal transition_to gets a terminal node and a jump edge" do
    saga = Class.new(SagaForge::Base) do
      def self.name = "MultiTerminalSaga"
      correlate_by :id
      start_with(:go10) { |_, _| }
      during(:reviewing, on: :decide) do |saga, payload|
        saga.transition_to :rejected if payload[:reject]
      end
      finish_with :approved
      finish_with :rejected
    end

    g = saga.definition.to_graph
    terminal_ids = g.nodes.select { |n| n.kind == :terminal }.map(&:id)
    assert_includes terminal_ids, "rejected"

    jumps = g.edges.select { |e| e.kind == :jump }.map { |e| [e.from, e.to] }
    assert_includes jumps, ["reviewing", "rejected"]
  end
end

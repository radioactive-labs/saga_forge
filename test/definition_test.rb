require "test_helper"

# Zeitwerk/Rails autoloading expects one constant per file matching the
# filename; this fixture intentionally defines two sagas in one file (to
# regression-test jump_targets cross-attribution), so it must be required
# explicitly rather than relying on autoload.
require_relative "support/multi_saga_file"

class DefinitionTest < SagaForge::TestCase
  test "chain built from file order" do
    d = OrderSaga.definition
    assert_equal :order_placed, d.start_event
    assert_equal :awaiting_settlement, d.successor_of(SagaForge::Definition::START)
    assert_equal :awaiting_review, d.successor_of(:awaiting_settlement)
    assert_equal :completed, d.successor_of(:awaiting_review)
    assert d.terminal?(:completed)
    assert d.terminal?(:compensated)
    assert d.terminal?(:cancelled)
  end

  test "state_for_event and events_for_state" do
    d = OrderSaga.definition
    assert_equal SagaForge::Definition::START, d.state_for_event(:order_placed)
    assert_equal :awaiting_settlement, d.state_for_event(:payment_settled)
    assert_equal %i[payment_settled payment_failed], d.events_for_state(:awaiting_settlement)
    assert_nil d.state_for_event(:unknown_event)
  end

  test "ambiguous event raises" do
    err = assert_raises(SagaForge::AmbiguousEventError) do
      Class.new(SagaForge::Base) do
        def self.name = "AmbiguousSaga"
        correlate_by :id
        start_with(:go) { |_, _| }
        during(:a, on: :tick) { |_, _| }
        during(:b, on: :tick) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/tick/, err.message)
  end

  test "unknown compensation raises" do
    assert_raises(SagaForge::UnknownCompensationError) do
      Class.new(SagaForge::Base) do
        def self.name = "BadCompSaga"
        correlate_by :id
        start_with(:go, compensate: :nope) { |_, _| }
        finish_with :done
      end.definition
    end
  end

  test "missing correlate_by, no terminal, and no start raise" do
    assert_raises(SagaForge::MissingCorrelationError) do
      Class.new(SagaForge::Base) do
        def self.name = "NoCorr"
        start_with(:go1) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_raises(SagaForge::NoTerminalStateError) do
      Class.new(SagaForge::Base) do
        def self.name = "NoFinish"
        correlate_by :id
        start_with(:go2) { |_, _| }
      end.definition
    end
    assert_raises(SagaForge::DefinitionError) do
      Class.new(SagaForge::Base) do
        def self.name = "NoStart"
        correlate_by :id
        during(:w, on: :tick2) { |_, _| }
        finish_with :done
      end.definition
    end
  end

  test "duplicate start_with on the same event raises DefinitionError, not AmbiguousEventError" do
    err = assert_raises(SagaForge::DefinitionError) do
      Class.new(SagaForge::Base) do
        def self.name = "DupStart"
        correlate_by :id
        start_with(:go4) { |_, _| }
        start_with(:go4) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/more than once/, err.message)
  end

  test "correlate: symbol sugar, block with event name, nil raises" do
    d = OrderSaga.definition
    assert_equal "42", d.correlate({"order_id" => 42}.with_indifferent_access, :order_placed)
    assert_raises(SagaForge::MissingCorrelationError) do
      d.correlate({}.with_indifferent_access, :order_placed)
    end

    block_saga = Class.new(SagaForge::Base) do
      def self.name = "BlockCorr"
      correlate_by { |p, event| (event == :special) ? p[:sid] : p[:id] }
      start_with(:special) { |_, _| }
      finish_with :done
    end
    assert_equal "s9", block_saga.definition.correlate({sid: "s9"}.with_indifferent_access, :special)
  end

  test "retry policy resolution ladder" do
    d = OrderSaga.definition
    h = d.handler_for(:payment_settled)
    assert_equal 3, d.retry_policy_for(h).max_attempts

    with_override = Class.new(SagaForge::Base) do
      def self.name = "RetrySaga"
      correlate_by :id
      retry_policy max_attempts: 7
      start_with(:go3, retry_policy: {max_attempts: 2}) { |_, _| }
      during(:w, on: :tick3) { |_, _| }
      finish_with :done
    end
    dd = with_override.definition
    assert_equal 2, dd.retry_policy_for(dd.handler_for(:go3)).max_attempts
    assert_equal 7, dd.retry_policy_for(dd.handler_for(:tick3)).max_attempts
  end

  test "to_mermaid draws chain and jump" do
    m = OrderSaga.to_mermaid
    assert_includes m, "stateDiagram-v2"
    assert_includes m, "[*] --> awaiting_settlement: order_placed"
    assert_includes m, "awaiting_settlement --> awaiting_review"
    assert_includes m, "completed --> [*]"
    assert_includes m, "awaiting_review --> completed: jump"
  end

  test "definition is deep-frozen: collections and Handler structs are frozen" do
    d = OrderSaga.definition
    assert d.frozen?
    assert d.handlers_by_event.frozen?
    assert d.handlers_by_event.values.all?(&:frozen?)
    assert d.compensations.frozen?
    assert d.states.frozen?
    assert d.terminal_states.frozen?
  end

  test "jump_targets does not cross-attribute between sagas sharing one file" do
    first_mermaid = FirstMultiSaga.to_mermaid
    second_mermaid = SecondMultiSaga.to_mermaid

    refute_match(/jump/, first_mermaid)
    assert_includes second_mermaid, "midway --> done: jump"
  end

  test "retry_policy raises when mixing a policy object with kwargs" do
    assert_raises(ArgumentError) do
      Class.new(SagaForge::Base) do
        def self.name = "MixedRetrySaga"
        correlate_by :id
        retry_policy SagaForge::RetryPolicy.new, base: 5
        start_with(:go5) { |_, _| }
        finish_with :done
      end
    end
  end
end

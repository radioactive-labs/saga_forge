require "test_helper"

# Zeitwerk/Rails autoloading expects one constant per file matching the
# filename; this fixture intentionally defines two sagas in one file (to
# regression-test jump_targets cross-attribution), so it must be required
# explicitly rather than relying on autoload.
require_relative "support/multi_saga_file"

class DefinitionTest < SagaForge::TestCase
  # Several tests below create throwaway Class.new(SagaForge::Base) fixtures
  # (including intentionally-broken ones) purely to exercise Definition
  # validations. Base.inherited registers every one of them into the global
  # Router, which would otherwise permanently pollute it for the rest of the
  # test process. Snapshot/restore around each test instead.
  setup { @router_snapshot = SagaForge::Router.saga_classes.dup }
  teardown { SagaForge::Router.instance_variable_set(:@classes, @router_snapshot) }

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

  test "on_timeout to an undeclared state raises DefinitionError at boot" do
    err = assert_raises(SagaForge::DefinitionError) do
      Class.new(SagaForge::Base) do
        def self.name = "BadTimeoutTargetSaga"
        correlate_by :id
        start_with(:go6) { |_, _| }
        during(:w, on: :tick6, timeout: 5.minutes, on_timeout: :nonexistent) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/tick6/, err.message)
  end

  test "timeout: without on_timeout: raises DefinitionError at boot" do
    err = assert_raises(SagaForge::DefinitionError) do
      Class.new(SagaForge::Base) do
        def self.name = "DanglingTimeoutSaga"
        correlate_by :id
        start_with(:go7) { |_, _| }
        during(:w, on: :tick7, timeout: 5.minutes) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/timeout: without on_timeout:/, err.message)
  end

  test "on_timeout: without timeout: raises DefinitionError at boot" do
    err = assert_raises(SagaForge::DefinitionError) do
      Class.new(SagaForge::Base) do
        def self.name = "DanglingOnTimeoutSaga"
        correlate_by :id
        start_with(:go8) { |_, _| }
        during(:w, on: :tick8, on_timeout: :fail!) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/on_timeout: without timeout:/, err.message)
  end

  test "on_timeout: :fail! (string or symbol) passes boot validation" do
    d = Class.new(SagaForge::Base) do
      def self.name = "OkTimeoutSaga"
      correlate_by :id
      start_with(:go9) { |_, _| }
      during(:w, on: :tick9, timeout: 5.minutes, on_timeout: "fail!") { |_, _| }
      finish_with :done
    end.definition
    assert_equal 5.minutes, d.handler_for(:tick9).timeout
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

  test "Router.recipients_for skips a class whose definition fails to compile, logging loudly" do
    Class.new(SagaForge::Base) do
      def self.name = "RouterBrokenSaga"
      correlate_by :id
      start_with(:router_broken_start) { |_, _| }
      during(:a, on: :router_tick) { |_, _| }
      during(:b, on: :router_tick) { |_, _| }
      finish_with :done
    end

    messages = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |&blk| messages << blk.call }

    original_logger = Rails.logger
    Rails.logger = fake_logger
    begin
      result = SagaForge::Router.recipients_for(:router_tick)
      assert_equal [], result.select { |k| k.name == "RouterBrokenSaga" }
    ensure
      Rails.logger = original_logger
    end

    assert(messages.any? { |m| m.include?("RouterBrokenSaga") },
      "expected the skip to be logged, got: #{messages.inspect}")
  end

  test "Router.compile_all! raises loudly when a registered saga's definition is broken" do
    Class.new(SagaForge::Base) do
      def self.name = "BootBrokenSaga"
      correlate_by :id
      start_with(:boot_broken_start) { |_, _| }
      # no finish_with — NoTerminalStateError
    end

    assert_raises(SagaForge::NoTerminalStateError) do
      SagaForge::Router.compile_all!
    end
  end
end

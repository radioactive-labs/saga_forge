require "test_helper"

class ExecutionCommitTest < SagaForge::TestCase
  def publish_rows(name, **payload)
    SagaForge.publish(name, **payload)
  end

  def run_all(rows)
    rows.each { |r| SagaForge::Execution::Runner.new(r).call }
  end

  test "start event creates row at successor state, processes event, backfills FK" do
    rows = publish_rows(:order_placed, order_id: 7, shipment_ref: "S1", total: 10)
    row = rows.find { |r| r.saga_class == "OrderSaga" }
    assert_equal [:done], SagaForge::Execution::Runner.new(row).call
    state = OrderSaga.find_by_correlation(7)
    assert_equal "awaiting_settlement", state.current_state
    assert_equal 1, state.version
    assert_equal 10, state.context["total"]
    assert row.reload.processed?
    assert_equal state.id, row.saga_forge_state_id
  end

  test "version conflict returns retry outcome, commits nothing, spares budgets" do
    state = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "9",
      current_state: "awaiting_settlement", version: 3)
    e = SagaForge::Event.create!(saga_class: "OrderSaga", correlation_id: "9",
      event_name: "payment_settled", payload: {})
    runner = SagaForge::Execution::Runner.new(e)
    # Simulate a concurrent commit landing between block run and commit:
    original = runner.method(:commit!)
    runner.define_singleton_method(:commit!) do |*args|
      SagaForge::State.where(id: state.id).update_all(version: 4)
      original.call(*args)
    end
    outcome, wait = runner.call
    assert_equal :retry, outcome
    assert wait.present?
    assert e.reload.pending?
    assert_equal 0, e.attempts
    assert_equal "awaiting_settlement", state.reload.current_state
  end

  test "staged publish inserts only at commit, delivered to recipient" do
    run_all(publish_rows(:order_placed, order_id: 7, shipment_ref: "S1", total: 10))
    e = publish_rows(:payment_settled, order_id: 7).first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    staged = SagaForge::Event.where(saga_class: "FulfillmentListenerSaga", correlation_id: "7", event_name: "order_fulfilled")
    assert_equal 1, staged.count
    assert staged.first.pending?
  end

  test "re-run after commit is a processed-skip; no double staged insert" do
    run_all(publish_rows(:order_placed, order_id: 8, shipment_ref: "S1", total: 1))
    e = publish_rows(:payment_settled, order_id: 8).first
    SagaForge::Execution::Runner.new(e).call
    assert_equal [:done], SagaForge::Execution::Runner.new(e.reload).call
    assert_equal 1, SagaForge::Event.where(saga_class: "FulfillmentListenerSaga", correlation_id: "8", event_name: "order_fulfilled").count
  end

  test "forward-only: a single tick advances StaySaga straight to :done_counting" do
    run_all(publish_rows(:start_counting, counter_id: 1))
    s = StaySaga.find_by_correlation(1)
    assert_equal "counting", s.current_state
    assert_equal 1, s.version

    run_all(publish_rows(:tick, counter_id: 1))
    s.reload
    assert_equal "done_counting", s.current_state
    assert_equal 2, s.version
    assert_equal 1, s.context["n"]
  end

  test "transition_to jumps to a declared target" do
    run_all(publish_rows(:order_placed, order_id: 11, shipment_ref: "S1", total: 10))
    run_all(publish_rows(:payment_settled, order_id: 11))
    e = publish_rows(:review_passed, order_id: 11).first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    assert_equal "completed", OrderSaga.find_by_correlation(11).current_state
  end

  test "transition_to an undeclared target raises UnknownStateError, routed through retry policy, leaving nothing committed" do
    run_all(publish_rows(:bad_jump_started, bad_jump_id: 99))
    state_before = BadJumpSaga.find_by_correlation(99)
    assert_equal "mid", state_before.current_state
    version_before = state_before.version

    e = publish_rows(:bad_jump_tick, bad_jump_id: 99).first
    # BadJumpSaga declares no retry_policy, so the default step_default
    # (retry_on: nil) matches UnknownStateError like any other block error:
    # the first failure (attempts 1 of 3) is retried rather than raised.
    outcome, wait = SagaForge::Execution::Runner.new(e).call
    assert_equal :retry, outcome
    assert wait.to_f.positive?

    e.reload
    assert e.pending?
    assert_equal 1, e.attempts
    state_after = state_before.reload
    assert_equal "mid", state_after.current_state
    assert_equal version_before, state_after.version
    assert_equal 2, SagaForge::Event.where(saga_class: "BadJumpSaga", correlation_id: "99").count
  end

  test "duplicate start race (concurrent create) returns retry outcome; exactly one state row exists" do
    e = publish_rows(:order_placed, order_id: 13, shipment_ref: "S2", total: 5)
      .find { |r| r.saga_class == "OrderSaga" }
    runner = SagaForge::Execution::Runner.new(e)
    # Simulate a concurrent commit that creates the same (saga_class,
    # correlation_id) row between this runner reading state_row = nil and
    # its own commit!'s State.create! — the unique index turns the second
    # creation into ActiveRecord::RecordNotUnique, which commit! maps to
    # ConcurrencyConflict.
    original = runner.method(:commit!)
    runner.define_singleton_method(:commit!) do |*args|
      SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "13",
        current_state: "awaiting_settlement", version: 0)
      original.call(*args)
    end
    outcome, wait = runner.call
    assert_equal :retry, outcome
    assert wait.present?
    assert e.reload.pending?
    assert_equal 1, SagaForge::State.where(saga_class: "OrderSaga", correlation_id: "13").count
  end

  test "fail! marks event processed, saves context snapshot, discards staged, goes compensating" do
    run_all(publish_rows(:order_placed, order_id: 12, shipment_ref: "S1", total: 10))
    e = publish_rows(:payment_failed, order_id: 12, code: "declined").first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    s = OrderSaga.find_by_correlation(12)
    assert_equal "compensating", s.current_state
    assert_equal "declined", s.context.dig("__saga_forge", "failure_reason")
    assert_equal "compensated", s.context.dig("__saga_forge", "target")
    assert e.reload.processed?
    assert_equal 0, SagaForge::Event.where(saga_class: "FulfillmentListenerSaga", correlation_id: "12").count
    assert_enqueued_with(job: SagaForge::CompensationJob, args: [s.id])
  end

  test "commit stamps state last_active_at and event last_processed_at, leaves finalized_at nil for a non-terminal advance" do
    rows = publish_rows(:order_placed, order_id: 20, shipment_ref: "S1", total: 10)
    row = rows.find { |r| r.saga_class == "OrderSaga" }
    assert_equal [:done], SagaForge::Execution::Runner.new(row).call
    state = OrderSaga.find_by_correlation(20)
    assert_not_nil state.last_active_at
    assert_nil state.finalized_at
    assert_not_nil row.reload.last_processed_at
  end

  test "reaching a terminal state via commit stamps finalized_at" do
    run_all(publish_rows(:order_placed, order_id: 21, shipment_ref: "S1", total: 10))
    run_all(publish_rows(:payment_settled, order_id: 21))
    run_all(publish_rows(:review_passed, order_id: 21))
    state = OrderSaga.find_by_correlation(21)
    assert_equal "completed", state.current_state
    assert_not_nil state.finalized_at
  end

  test "staged insert colliding with an existing recipient row is benign; commit still succeeds, exactly one row survives" do
    # Pre-create the exact (saga_class, correlation_id, event_name) row that
    # OrderSaga's payment_settled handler is about to stage — as if it had
    # already arrived from another producer, or a redelivery.
    pre = publish_rows(:order_fulfilled, order_id: 14).first
    assert pre.pending?

    run_all(publish_rows(:order_placed, order_id: 14, shipment_ref: "S1", total: 10))
    e = publish_rows(:payment_settled, order_id: 14).first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call

    state = OrderSaga.find_by_correlation(14)
    assert_equal "awaiting_review", state.current_state
    assert_equal 2, state.version
    assert e.reload.processed?

    rows = SagaForge::Event.where(saga_class: "FulfillmentListenerSaga", correlation_id: "14", event_name: "order_fulfilled")
    assert_equal 1, rows.count
    assert_equal pre.id, rows.first.id
  end
end

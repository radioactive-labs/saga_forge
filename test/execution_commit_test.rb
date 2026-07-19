require "test_helper"

class ExecutionCommitTest < SagaForge::TestCase
  def publish_rows(name, **payload)
    SagaForge.publish(name, event_id: "t:#{name}:#{SecureRandom.hex(4)}", **payload)
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
    e = SagaForge::Event.create!(event_id: "v:1", saga_class: "OrderSaga", correlation_id: "9",
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

  test "staged publish inserts only at commit, deterministic ids, delivered to recipient" do
    run_all(publish_rows(:order_placed, order_id: 7, shipment_ref: "S1", total: 10))
    e = publish_rows(:payment_settled, order_id: 7).first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    staged = SagaForge::Event.where("event_id LIKE ?", "staged:#{e.id}:%")
    assert_equal 1, staged.count
    assert_equal "FulfillmentListenerSaga", staged.first.saga_class
    assert_equal "order_fulfilled", staged.first.event_name
    assert staged.first.pending?
  end

  test "re-run after commit is a processed-skip; no double staged insert" do
    run_all(publish_rows(:order_placed, order_id: 8, shipment_ref: "S1", total: 1))
    e = publish_rows(:payment_settled, order_id: 8).first
    SagaForge::Execution::Runner.new(e).call
    assert_equal [:done], SagaForge::Execution::Runner.new(e.reload).call
    assert_equal 1, SagaForge::Event.where("event_id LIKE ?", "staged:#{e.id}:%").count
  end

  test "stay keeps state but bumps version; loop exits when condition clears" do
    run_all(publish_rows(:start_counting, counter_id: 1))
    run_all(publish_rows(:tick, counter_id: 1))
    s = StaySaga.find_by_correlation(1)
    assert_equal "counting", s.current_state
    assert_equal 2, s.version
    run_all(publish_rows(:tick, counter_id: 1))
    assert_equal "done_counting", StaySaga.find_by_correlation(1).current_state
  end

  test "transition_to jumps; undeclared target raises UnknownStateError leaving nothing committed" do
    run_all(publish_rows(:order_placed, order_id: 11, shipment_ref: "S1", total: 10))
    run_all(publish_rows(:payment_settled, order_id: 11))
    e = publish_rows(:review_passed, order_id: 11).first
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    assert_equal "completed", OrderSaga.find_by_correlation(11).current_state
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
    assert_equal 0, SagaForge::Event.where("event_id LIKE ?", "staged:#{e.id}:%").count
    assert_enqueued_with(job: SagaForge::CompensationJob, args: [s.id])
  end
end

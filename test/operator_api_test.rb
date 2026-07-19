require "test_helper"

class OperatorApiTest < SagaForge::TestCase
  test "retry_stalled! re-delivers parked events in ledger order" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "1", current_state: "awaiting_settlement")
    e2 = SagaForge::Event.create!(event_id: "o2", saga_class: "OrderSaga", correlation_id: "1",
      event_name: "payment_failed", status: :stalled, stall_count: 40, state: s, created_at: 1.minute.ago)
    e1 = SagaForge::Event.create!(event_id: "o1", saga_class: "OrderSaga", correlation_id: "1",
      event_name: "payment_settled", status: :stalled, stall_count: 40, state: s, created_at: 2.minutes.ago)
    assert s.retry_stalled!
    assert e1.reload.pending?
    assert e2.reload.pending?
    assert_equal 0, e1.stall_count
    args = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::ExecutionJob" }.map { |j| j["arguments"] }
    assert_equal [[e1.id], [e2.id]], args # ledger order: e1 older
  end

  test "resume! fully resets failed events" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "2", current_state: "awaiting_settlement")
    e = SagaForge::Event.create!(event_id: "o3", saga_class: "OrderSaga", correlation_id: "2",
      event_name: "payment_settled", status: :failed, attempts: 3,
      retry_budgets: {"X" => 3}, error: {"class" => "X"}, state: s)
    assert s.resume!
    e.reload
    assert e.pending?
    assert_equal 0, e.attempts
    assert_equal({}, e.retry_budgets)
    assert_nil e.error
    args = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::ExecutionJob" }.map { |j| j["arguments"] }
    assert_equal [[e.id]], args
  end

  test "retry_stalled! and resume! no-op (and warn) on terminal or compensating sagas" do
    done = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "54", current_state: "completed")
    stalled = SagaForge::Event.create!(event_id: "o5", saga_class: "OrderSaga", correlation_id: "54",
      event_name: "payment_settled", status: :stalled, state: done)
    logged = capture_saga_log(:warn) { refute done.retry_stalled! }
    assert_match(/retry_stalled!/, logged)
    assert stalled.reload.stalled? # untouched
    assert_no_enqueued_jobs only: SagaForge::ExecutionJob

    comping = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "55", current_state: "compensating")
    failed = SagaForge::Event.create!(event_id: "o6", saga_class: "OrderSaga", correlation_id: "55",
      event_name: "payment_settled", status: :failed, state: comping)
    logged = capture_saga_log(:warn) { refute comping.resume! }
    assert_match(/resume!/, logged)
    assert failed.reload.failed? # untouched
    assert_no_enqueued_jobs only: SagaForge::ExecutionJob
  end

  test "retry_stalled! and resume! return false when there is nothing to do" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "56", current_state: "awaiting_settlement")
    refute s.retry_stalled!
    refute s.resume!
  end

  test "resume! then reprocessing completes the saga (resume-then-compensate part 1)" do
    # Drive FlakySaga to a failed event, then fix the payload and resume
    e = SagaForge.publish(:flaky_started, event_id: "op-r1", id: "opr1", mode: "unmatched").first
    SagaForge::Execution::Runner.new(e).call
    assert e.reload.failed?
    s = FlakySaga.find_by_correlation("opr1")
    assert_nil s # start block failed → no saga row yet
    e.update!(payload: e.payload.merge("mode" => "ok"))
    # No saga row exists — resume the failed event directly through Event:
    e.update!(status: :pending, attempts: 0, retry_budgets: {}, error: nil)
    perform_enqueued_jobs { SagaForge::ExecutionJob.perform_later(e.id) }
    assert_equal "flaky_done", FlakySaga.find_by_correlation("opr1").current_state
  end

  test "cancel! compensates then lands in :cancelled with reason" do
    perform_enqueued_jobs do
      SagaForge.publish(:lifo_order_placed, event_id: "op-c1", order_id: 50)
    end
    s = LifoOrderSaga.find_by_correlation(50)
    perform_enqueued_jobs { s.cancel!(reason: "operator") }
    s.reload
    assert_equal "cancelled", s.current_state
    assert_equal "operator", s.context.dig("__saga_forge", "failure_reason")
    assert_equal ["refund"], s.context.dig("__saga_forge", "compensated")
  end

  test "compensate! warns when failed events exist but still proceeds" do
    s = SagaForge::State.create!(saga_class: "LifoOrderSaga", correlation_id: "51", current_state: "awaiting_settlement")
    SagaForge::Event.create!(event_id: "o4", saga_class: "LifoOrderSaga", correlation_id: "51",
      event_name: "lifo_payment_settled", status: :failed, state: s)
    logged = capture_saga_log(:warn) { assert s.compensate! }
    assert_match(/resume!/, logged)
    assert_equal "compensating", s.reload.current_state
  end

  test "compensate! no-ops on terminal and already-compensating sagas" do
    done = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "52", current_state: "completed")
    refute done.compensate!
    assert_equal "completed", done.reload.current_state
    assert_no_enqueued_jobs only: SagaForge::CompensationJob

    comping = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "53", current_state: "compensating")
    refute comping.compensate!
    assert_no_enqueued_jobs only: SagaForge::CompensationJob
  end

  test "compensate! does not warn about failed events when the saga is already terminal" do
    done = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "57", current_state: "completed")
    SagaForge::Event.create!(event_id: "o7", saga_class: "OrderSaga", correlation_id: "57",
      event_name: "payment_settled", status: :failed, state: done)
    logged = capture_saga_log(:warn) { refute done.compensate! }
    assert_empty logged
  end

  test "cancel! no-ops on a terminal saga" do
    done = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "58", current_state: "completed")
    refute done.cancel!(reason: "operator")
    assert_equal "completed", done.reload.current_state
    assert_nil done.context.dig("__saga_forge", "failure_reason")
    assert_no_enqueued_jobs only: SagaForge::CompensationJob
  end

  private

  def capture_saga_log(_level)
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = old
  end
end

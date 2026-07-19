require "test_helper"

class ExecutionLifecycleTest < SagaForge::TestCase
  def make_event(name: "payment_settled", corr: "1", status: :pending, **attrs)
    SagaForge::Event.create!(event_id: SecureRandom.uuid, saga_class: "OrderSaga",
      correlation_id: corr, event_name: name, status: status, payload: {}, **attrs)
  end

  def make_state(corr: "1", state: "awaiting_settlement")
    SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: corr, current_state: state)
  end

  test "missing row retries then discards silently" do
    assert_nothing_raised do
      SagaForge::ExecutionJob.perform_now(-1)
    end
    assert_enqueued_jobs 1, only: SagaForge::ExecutionJob
  end

  test "missing row discards silently once retries are exhausted" do
    job = SagaForge::ExecutionJob.new(-1)
    # perform_now increments `executions` by 1 before calling #perform, so
    # priming it at NOT_FOUND_RETRIES - 1 lands exactly on the threshold
    # (executions == NOT_FOUND_RETRIES) inside perform — the last attempt
    # that must NOT retry. Empirically confirmed: priming at NOT_FOUND_RETRIES
    # itself overshoots to NOT_FOUND_RETRIES + 1, still discarding but past
    # the exact boundary.
    job.executions = SagaForge::ExecutionJob::NOT_FOUND_RETRIES - 1
    assert_nothing_raised { job.perform_now }
    assert_equal SagaForge::ExecutionJob::NOT_FOUND_RETRIES, job.executions
    assert_no_enqueued_jobs
  end

  test "processed, stalled, and failed rows exit immediately" do
    make_state
    %i[processed stalled failed].each do |st|
      e = make_event(status: st, corr: "1")
      assert_equal [:done], SagaForge::Execution::Runner.new(e).call
      assert_equal st.to_s, e.reload.status
    end
  end

  test "halt: failed event blocks pending siblings, saga untouched" do
    s = make_state
    make_event(name: "payment_failed", status: :failed)
    pending = make_event(name: "payment_settled")
    assert_equal [:done], SagaForge::Execution::Runner.new(pending).call
    assert pending.reload.pending?
    assert_equal "awaiting_settlement", s.reload.current_state
  end

  test "early event spins then parks; retry budgets untouched" do
    SagaForge.configure { |c| c.stall_budget = 2 }
    make_state(state: "awaiting_review") # saga is past awaiting_settlement
    e = make_event(name: "payment_settled")
    assert_equal [:respin], SagaForge::Execution::Runner.new(e).call
    assert_equal 1, e.reload.stall_count
    assert e.reload.pending?
    assert_equal [:done], SagaForge::Execution::Runner.new(e.reload).call
    assert e.reload.stalled?
    assert_equal 2, e.stall_count
    assert_equal 0, e.attempts
  end

  test "orphan during-event parks; re-delivered start event parks" do
    SagaForge.configure { |c| c.stall_budget = 1 }
    orphan = make_event(name: "payment_settled", corr: "404")
    assert_equal [:done], SagaForge::Execution::Runner.new(orphan).call
    assert orphan.reload.stalled?

    make_state(corr: "2", state: "awaiting_settlement")
    dup_start = make_event(name: "order_placed", corr: "2")
    assert_equal [:done], SagaForge::Execution::Runner.new(dup_start).call
    assert dup_start.reload.stalled?
  end

  test "terminal instance discards with note" do
    make_state(state: "completed")
    e = make_event(name: "payment_settled")
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    assert e.reload.processed?
    assert_equal "terminal state completed", e.error["discarded"]
  end

  test "job respins early events via retry_job with stall_wait" do
    make_state(state: "awaiting_review")
    e = make_event(name: "payment_settled")
    SagaForge::ExecutionJob.perform_now(e.id)
    assert_equal 1, e.reload.stall_count
    assert_enqueued_jobs 1, only: SagaForge::ExecutionJob
  end

  test "matched event reaches execute! (Task 6 boundary)" do
    make_state(corr: "9", state: "awaiting_settlement")
    e = make_event(name: "payment_settled", corr: "9")
    assert_raises(NotImplementedError) { SagaForge::Execution::Runner.new(e).call }
  end
end

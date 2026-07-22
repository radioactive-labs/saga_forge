require "test_helper"

# Torture tests for the atomicity invariants that make the rest of the suite
# possible: a failed pass must leave no trace of what it staged (§A.1's
# commit-at-end), a committed pass must never be re-run by a redelivery
# (§A.2/§A.3's processed-skip), a lost enqueue must still be recoverable by
# the sweeper (Task 6 review), and a version race between two runners must
# resolve to exactly one winner.
#
# chaotic_job bonus scenario: SKIPPED, with reasons. chaotic_job's
# `run_scenario` model injects a transient error via TracePoint and relies on
# ActiveJob's own `retry_on`/perform-raises-and-retries machinery to recover
# (see Scenario#run, which calls `@job.class.retry_on RetryableError, ...`).
# SagaForge::ExecutionJob never raises from #perform for a block failure —
# Execution::Runner#execute! rescues the block's error internally and routes
# it through the saga's own retry policy (Runner#handle_error), returning
# [:retry, wait] or [:done] rather than letting anything escape to ActiveJob.
# There is no point in the job's #perform where a chaotic_job glitch would
# have a chance to be caught by ActiveJob's retry_on, so the gem's fault-
# injection model doesn't have a natural hook here. The deterministic tests
# below (a class-level attempt counter standing in for chaotic_job's
# TracePoint glitch) are the required, and only, torture coverage.
class DurabilityTest < SagaForge::TestCase
  setup { GlitchSaga.attempts_seen = 0 }

  test "no ghost cascade: staged publish from a failed pass never surfaces" do
    row = SagaForge.publish(:g_started, id: 1).first

    outcome, = SagaForge::Execution::Runner.new(row).call # pass 1: raises mid-block
    assert_equal :retry, outcome
    assert_equal 0, SagaForge::Event.where(event_name: "g_echo").count, "the failed pass's staged publish must not surface"
    assert row.reload.pending?

    outcome, = SagaForge::Execution::Runner.new(row.reload).call # pass 2: commits clean
    assert_equal :done, outcome
    assert_equal 1, SagaForge::Event.where(event_name: "g_echo").count
    assert_equal "1", SagaForge::Event.find_by(event_name: "g_echo").correlation_id
  end

  test "re-delivery after commit is a processed-skip, no double staged insert" do
    GlitchSaga.attempts_seen = 99 # no glitch this pass
    row = SagaForge.publish(:g_started, id: 2).first

    assert_equal [:done], SagaForge::Execution::Runner.new(row).call
    assert_equal [:done], SagaForge::Execution::Runner.new(row.reload).call # re-delivery: processed-skip
    assert_equal 1, SagaForge::Event.where(event_name: "g_echo", correlation_id: "2").count
  end

  test "concurrent version race over an existing instance: loser retries, exactly one commit lands" do
    GlitchSaga.attempts_seen = 99
    start_row = SagaForge.publish(:g_started, id: 3).first
    assert_equal [:done], SagaForge::Execution::Runner.new(start_row).call
    state = GlitchSaga.find_by_correlation(3)
    assert_equal "awaiting_g_echo", state.current_state

    e = SagaForge.publish(:g_advance, id: 3).first
    runner = SagaForge::Execution::Runner.new(e)
    original_commit = runner.method(:commit!)
    runner.define_singleton_method(:commit!) do |*args|
      # A second runner for the same instance commits first, bumping the
      # version underneath this one between its read and its own commit.
      SagaForge::State.where(id: state.id).update_all(version: state.version + 1)
      original_commit.call(*args)
    end

    outcome, wait = runner.call
    assert_equal :retry, outcome
    assert wait.present?
    assert e.reload.pending?, "the loser's event must stay pending, not processed"
    assert_equal 0, e.attempts, "a version conflict is not a block failure — it must not burn retry-policy budget"
    assert_equal "awaiting_g_echo", state.reload.current_state, "the loser's commit must not have landed"

    # The loser retries clean: re-running the same event now (no more races) commits.
    assert_equal [:done], SagaForge::Execution::Runner.new(e.reload).call
    assert_equal "done", state.reload.current_state
  end

  # Task 6 review: a fail!/compensate! handoff is a once-only hint — a crash
  # between the commit that lands a saga in :compensating and the
  # CompensationJob enqueue strands it forever unless the sweeper recovers it.
  test "crash window: fail! commits but the CompensationJob enqueue is lost — sweeper recovers" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:order_placed, order_id: 900, shipment_ref: "S1", total: 5)
    end
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:payment_failed, order_id: 900, code: "declined")
    end
    s = OrderSaga.find_by_correlation(900)
    assert_equal "compensating", s.current_state, "fail! must have committed for real before we simulate the crash"

    # CRASH POINT: the commit above landed (current_state == compensating),
    # but imagine the process died right after, before
    # `CompensationJob.perform_later(state.id)` ran (Execution::Runner#after_commit_effects).
    # Simulate the lost enqueue by discarding it, then backdate past the
    # sweeper's cutoff so the stranding looks aged, not in-flight.
    clear_enqueued_jobs
    s.update_columns(last_active_at: 5.minutes.ago)

    SagaForge::SweeperJob.perform_now
    assert_enqueued_with(job: SagaForge::CompensationJob, args: [s.id])
  end

  # Task 6 review: a crash between a commit and its redeliver_parked call
  # strands a parked event the saga is now genuinely waiting on — no future
  # commit will ever re-deliver it, since redelivery only fires for the
  # state a live commit just entered.
  test "crash window: commit landed but redeliver_parked never ran — sweeper redelivers the parked event" do
    # CRASH POINT: the saga is really at awaiting_g_echo (as if a commit just
    # landed it there), but Execution::Runner#after_commit_effects's
    # redeliver_parked call never ran. A g_advance event that arrived earlier
    # is still :stalled, and nobody else will ever flip it back to pending.
    state = SagaForge::State.create!(saga_class: "GlitchSaga", correlation_id: "4",
      current_state: "awaiting_g_echo")
    parked = SagaForge::Event.create!(saga_class: "GlitchSaga",
      correlation_id: "4", event_name: "g_advance", status: :stalled, stall_count: 40,
      state: state, updated_at: 5.minutes.ago)

    SagaForge::SweeperJob.perform_now

    assert parked.reload.pending?
    assert_equal 0, parked.stall_count
    assert_enqueued_with(job: SagaForge::ExecutionJob, args: [parked.id])
  end
end

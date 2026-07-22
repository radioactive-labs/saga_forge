require "test_helper"

class RetryIntegrationTest < SagaForge::TestCase
  def row(mode:, corr: SecureRandom.hex(4))
    SagaForge.publish(:flaky_started, id: corr, mode: mode).first
  end

  test "retryable error increments attempts and budget, stays pending, returns backoff" do
    e = row(mode: "flaky")
    outcome, wait = SagaForge::Execution::Runner.new(e).call
    assert_equal :retry, outcome
    assert wait.to_f.positive?
    e.reload
    assert e.pending?
    assert_equal 1, e.attempts
    assert_equal 1, e.retry_budgets[FlakySaga::FlakyError.name]
    assert_nil SagaForge::State.find_by(saga_class: "FlakySaga", correlation_id: e.correlation_id)
  end

  test "exhaustion marks failed with traceback and activates halt" do
    e = row(mode: "fatal", corr: "halt1")
    SagaForge::Execution::Runner.new(e).call # attempt 1 of max 1 → failed
    e.reload
    assert e.failed?
    assert_equal "FlakySaga::FatalError", e.error["class"]
    assert e.error["backtrace"].any?

    # Any other pending row for this instance — the halted? check fires
    # before event_name is ever consulted, so a distinct name here (required
    # by the structural (saga_class, correlation_id, event_name) unique
    # index) still proves a failed sibling blocks it.
    sibling = SagaForge::Event.create!(saga_class: "FlakySaga",
      correlation_id: "halt1", event_name: "flaky_retry_probe", payload: {})
    assert_equal [:done], SagaForge::Execution::Runner.new(sibling).call
    assert sibling.reload.pending?
  end

  test "unmatched error fails fast on first attempt" do
    e = row(mode: "unmatched")
    SagaForge::Execution::Runner.new(e).call
    assert e.reload.failed?
    assert_equal 1, e.attempts
    assert_equal "RuntimeError", e.error["class"]
  end

  test "per-declared-error budgets are independent and exhaust correctly" do
    e = row(mode: "flaky")
    outcomes = 3.times.map { SagaForge::Execution::Runner.new(e.reload).call.first }
    assert_equal [:retry, :retry, :done], outcomes
    e.reload
    assert e.failed?
    assert_equal 3, e.attempts
    assert_equal 3, e.retry_budgets[FlakySaga::FlakyError.name]
  end

  test "composite routes subclass errors to the parent policy's budget" do
    e = row(mode: "sub_flaky")
    SagaForge::Execution::Runner.new(e).call
    assert_equal 1, e.reload.retry_budgets[FlakySaga::FlakyError.name]
  end

  test "plain (non-composite) policy does not write retry_budgets" do
    e = SagaForge.publish(:plain_started, id: "1").first
    outcome, = SagaForge::Execution::Runner.new(e).call
    assert_equal :retry, outcome
    assert_equal({}, e.reload.retry_budgets)
    assert_equal 1, e.attempts
  end

  test "successful run after retryable failures completes normally" do
    e = row(mode: "flaky")
    SagaForge::Execution::Runner.new(e).call
    e.reload.update!(payload: e.payload.merge("mode" => "ok"))
    assert_equal [:done], SagaForge::Execution::Runner.new(e.reload).call
    assert e.reload.processed?
  end

  # Reproduces the lost-update hazard: two deliveries each load the row
  # while attempts is still 0 (stale in-memory), then both hit handle_error's
  # block-failure path. Without the row lock, both would independently
  # compute attempts=1 and one increment would be lost. With the lock, the
  # second delivery's with_lock reload sees the first's committed attempts,
  # so the count is never lost — deterministic here because PlainRetrySaga's
  # policy (max_attempts: 2) exhausts exactly on the counted 2nd attempt.
  test "concurrent deliveries reading stale attempts never lose the increment" do
    id = SecureRandom.hex(4)
    first = SagaForge.publish(:plain_started, id: id).first

    e1 = SagaForge::Event.find(first.id)
    e2 = SagaForge::Event.find(first.id) # separate in-memory copy, also stale attempts: 0

    outcome1, = SagaForge::Execution::Runner.new(e1).call
    outcome2, = SagaForge::Execution::Runner.new(e2).call

    assert_equal :retry, outcome1
    assert_equal :done, outcome2

    row = SagaForge::Event.find(first.id)
    assert_equal 2, row.attempts
    assert row.failed?
  end

  test "invalid-byte error message is scrubbed instead of crashing the failure write" do
    e = row(mode: "binary")
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    e.reload
    assert e.failed?
    assert_equal "FlakySaga::FatalError", e.error["class"]
    assert_includes e.error["message"], "\u{FFFD}"
  end
end

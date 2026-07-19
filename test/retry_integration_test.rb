require "test_helper"

class RetryIntegrationTest < SagaForge::TestCase
  def row(mode:, corr: SecureRandom.hex(4))
    SagaForge.publish(:flaky_started, event_id: "f:#{mode}:#{corr}", id: corr, mode: mode).first
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

    sibling = SagaForge::Event.create!(event_id: "sib:halt1", saga_class: "FlakySaga",
      correlation_id: "halt1", event_name: "flaky_started", payload: {})
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
    e = SagaForge.publish(:plain_started, event_id: "p:#{SecureRandom.hex(4)}", id: "1").first
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
end

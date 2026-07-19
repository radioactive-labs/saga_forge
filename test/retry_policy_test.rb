require "test_helper"

class RetryPolicyTest < SagaForge::TestCase
  test "backoff is capped exponential with equal jitter bounds" do
    p = SagaForge::RetryPolicy.new(base: 2, cap: 60, jitter: true)
    d = p.backoff_for(3) # raw = min(60, 2*2^2) = 8
    assert_includes 4.0..8.0, d.to_f
  end

  test "backoff without jitter is deterministic and capped" do
    p = SagaForge::RetryPolicy.new(base: 2, cap: 10, jitter: false)
    assert_equal 2.seconds, p.backoff_for(1)
    assert_equal 8.seconds, p.backoff_for(3)
    assert_equal 10.seconds, p.backoff_for(10) # capped
  end

  test "retry_on list matches subclasses; [] retries nothing; nil any StandardError" do
    io = SagaForge::RetryPolicy.new(retry_on: [IOError])
    assert io.matches?(EOFError.new)
    refute io.matches?(ArgumentError.new)
    none = SagaForge::RetryPolicy.new(retry_on: [])
    refute none.matches?(StandardError.new)
    any = SagaForge::RetryPolicy.new
    assert any.matches?(RuntimeError.new)
  end

  test "attempt cap: attempts is 1-based including current failure" do
    p = SagaForge::RetryPolicy.new(max_attempts: 3, jitter: false)
    assert p.retryable?(RuntimeError.new, 1)
    assert p.retryable?(RuntimeError.new, 2)
    refute p.retryable?(RuntimeError.new, 3)
  end

  test "budget_key stable under reordering" do
    p = SagaForge::RetryPolicy.new(retry_on: [IOError, ArgumentError])
    assert_equal "ArgumentError,IOError", p.budget_key
    assert_equal "*", SagaForge::RetryPolicy.new.budget_key
  end

  test "composite routes first match, unmatched errors fail fast" do
    composite = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(retry_on: [IOError], max_attempts: 5),
      SagaForge::RetryPolicy.new(retry_on: [ArgumentError], max_attempts: 1)
    ])
    assert composite.retry_backoff(IOError.new, attempts: 1)
    assert_nil composite.retry_backoff(ArgumentError.new, attempts: 1)
    assert_nil composite.retry_backoff(RuntimeError.new, attempts: 0)
  end

  test "composite block form supplies per-budget count" do
    composite = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(retry_on: [IOError], max_attempts: 2)
    ])
    result = composite.retry_backoff(IOError.new, attempts: 99) { |budget_key| 1 }
    assert result
  end

  test "composite max_attempts is coarsest bound, nil when any unbounded" do
    bounded = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(retry_on: [IOError], max_attempts: 5),
      SagaForge::RetryPolicy.new(max_attempts: 2)
    ])
    assert_equal 5, bounded.max_attempts
    unbounded = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(max_attempts: nil)
    ])
    assert_nil unbounded.max_attempts
  end

  test "empty composite raises" do
    assert_raises(ArgumentError) { SagaForge::CompositeRetryPolicy.new([]) }
  end

  test "saga defaults" do
    assert_equal 3, SagaForge::RetryPolicy.step_default.max_attempts
    assert_equal 10, SagaForge::RetryPolicy.compensation_default.max_attempts
    assert_equal 600, SagaForge::RetryPolicy.compensation_default.cap
    refute SagaForge::RetryPolicy.respond_to?(:wait_default)
  end
end

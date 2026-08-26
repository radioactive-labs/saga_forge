require "test_helper"

# Integration check against the real solid_queue gem. The unit tests in
# concurrency_controls_test.rb exercise each job's CONCURRENCY_KEY constant in
# isolation; this file is the one place the constant is fed through the REAL
# ActiveJob::ConcurrencyControls macro, so the gem's own semantics — group/key
# joining, the instance_exec'd key proc, and ruby2_keywords argument flow — are
# what's under test, not a stand-in.
#
# Two load-order details make this safe (see concurrency_controls_test.rb for
# the background):
#
#   1. The real job classes are referenced BEFORE `require "solid_queue"`, so
#      their `if defined?(SolidQueue)` guards evaluate while SolidQueue is still
#      undefined — skipped, and the classes are cached inert. (Touching them
#      after the require would fire the guard's `limits_concurrency` before
#      solid_queue's engine has mixed ConcurrencyControls into ActiveJob::Base,
#      raising NoMethodError.)
#   2. solid_queue is required post-boot, so its engine initializer never runs
#      and ActiveJob::Base stays clean for the rest of the suite. The probes
#      below include ActiveJob::ConcurrencyControls explicitly instead.
[SagaForge::ExecutionJob, SagaForge::CompensationJob, SagaForge::TimeoutJob,
  SagaForge::SweeperJob, SagaForge::RetentionJob].each { |k| k.name }

require "solid_queue"

class SolidQueueIntegrationTest < ActiveJob::TestCase
  # Probes wire the REAL CONCURRENCY_KEY constants through the REAL macro. The
  # concurrency_group defaults to the job class name, so the composed key is
  # "<JobClass>/<key>" — for the shipped jobs that's "SagaForge::ExecutionJob/…"
  # etc. (a per-class semaphore; correctness itself rides the DB version fence,
  # per the design spec — limits_concurrency is only a throughput optimization).
  class ExecProbe < ActiveJob::Base
    include ActiveJob::ConcurrencyControls

    limits_concurrency key: SagaForge::ExecutionJob::CONCURRENCY_KEY
  end

  class TimeoutProbe < ActiveJob::Base
    include ActiveJob::ConcurrencyControls

    limits_concurrency key: SagaForge::TimeoutJob::CONCURRENCY_KEY
  end

  class SweeperProbe < ActiveJob::Base
    include ActiveJob::ConcurrencyControls

    limits_concurrency key: SagaForge::SweeperJob::CONCURRENCY_KEY
  end

  test "a dynamic per-saga key composes into a real semaphore key" do
    event = SagaForge::Event.create!(saga_class: "OrderSaga",
      correlation_id: "7", event_name: "order_placed")

    job = ExecProbe.new(event.id)
    assert_equal "SolidQueueIntegrationTest::ExecProbe/SagaLock:OrderSaga:7", job.concurrency_key
    assert job.concurrency_limited?
  end

  test "a missing row falls back to the shared miss key, still limited" do
    job = ExecProbe.new(-1)
    assert_equal "SolidQueueIntegrationTest::ExecProbe/SagaLock:none", job.concurrency_key
    assert job.concurrency_limited?
  end

  test "the timeout key proc soaks the extra job arguments" do
    state = SagaForge::State.create!(saga_class: "OrderSaga",
      correlation_id: "9", current_state: "awaiting_settlement")

    job = TimeoutProbe.new(state.id, "payment_settled", 3)
    assert_equal "SolidQueueIntegrationTest::TimeoutProbe/SagaLock:OrderSaga:9", job.concurrency_key
  end

  test "a static singleton key composes without touching the arguments" do
    job = SweeperProbe.new
    assert_equal "SolidQueueIntegrationTest::SweeperProbe/SagaForge::Sweeper", job.concurrency_key
    assert job.concurrency_limited?
  end

  test "solid_queue's own defaults fall through where the jobs don't override" do
    # The shipped jobs pass only `key:`; to (limit) and on_conflict are left to
    # solid_queue's defaults — a single holder, blocking on conflict.
    assert_equal 1, ExecProbe.concurrency_limit
    assert_equal :block, ExecProbe.concurrency_on_conflict
  end
end

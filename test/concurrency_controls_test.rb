require "test_helper"

# Solid Queue coverage (Task 5 review deferral): the job classes declare
# `limits_concurrency key: ...` under `if defined?(SolidQueue)`, but the test
# env loads solid_queue with `require: false` (see Gemfile) and Combustion has
# already booted, so `SolidQueue::Engine`'s initializer never mixes
# ConcurrencyControls into ActiveJob::Base for the base suite. Each job extracts
# its key logic into a CONCURRENCY_KEY constant (lambda or plain string) that IS
# what limits_concurrency is handed when the guard passes — testing the constant
# directly exercises the exact same object Solid Queue would call, with no
# reliance on the adapter being booted.
#
# For the complementary check that feeds these constants through the REAL
# ActiveJob::ConcurrencyControls macro (group/key joining, arg flow), see
# test/solid_queue_integration_test.rb, which requires solid_queue post-boot and
# probes it in isolation.
class ConcurrencyControlsTest < SagaForge::TestCase
  test "ExecutionJob::CONCURRENCY_KEY resolves a found row to a per-saga lock, else a shared miss key" do
    e = SagaForge::Event.create!(saga_class: "OrderSaga",
      correlation_id: "7", event_name: "order_placed")
    assert_equal "SagaLock:OrderSaga:7", SagaForge::ExecutionJob::CONCURRENCY_KEY.call(e.id)
    assert_equal "SagaLock:none", SagaForge::ExecutionJob::CONCURRENCY_KEY.call(-1)
  end

  test "CompensationJob::CONCURRENCY_KEY resolves a found row to a per-saga lock, else a shared miss key" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "8", current_state: "compensating")
    assert_equal "SagaLock:OrderSaga:8", SagaForge::CompensationJob::CONCURRENCY_KEY.call(s.id)
    assert_equal "SagaLock:none", SagaForge::CompensationJob::CONCURRENCY_KEY.call(-1)
  end

  test "TimeoutJob::CONCURRENCY_KEY resolves a found row to a per-saga lock, ignoring the extra arguments" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "9", current_state: "awaiting_settlement")
    assert_equal "SagaLock:OrderSaga:9", SagaForge::TimeoutJob::CONCURRENCY_KEY.call(s.id, "payment_settled", 3)
    assert_equal "SagaLock:none", SagaForge::TimeoutJob::CONCURRENCY_KEY.call(-1, "payment_settled", 3)
  end

  test "SweeperJob and RetentionJob use fixed singleton keys, not per-instance ones" do
    assert_equal "SagaForge::Sweeper", SagaForge::SweeperJob::CONCURRENCY_KEY
    assert_equal "SagaForge::Retention", SagaForge::RetentionJob::CONCURRENCY_KEY
  end
end

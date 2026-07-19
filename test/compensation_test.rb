require "test_helper"

class CompensationTest < SagaForge::TestCase
  test "fail! compensates processed steps LIFO and lands in :compensated" do
    perform_enqueued_jobs do
      SagaForge.publish(:lifo_order_placed, event_id: "c1", order_id: 5, total: 9)
      SagaForge.publish(:lifo_payment_settled, event_id: "c2", order_id: 5)
      SagaForge.publish(:lifo_payment_failed, event_id: "c3", order_id: 5, code: "card_declined")
    end
    s = LifoOrderSaga.find_by_correlation(5)
    assert_equal "compensated", s.current_state
    meta = s.context["__saga_forge"]
    assert_equal "card_declined", meta["failure_reason"]
    assert_equal %w[release_stock refund], meta["compensated"] # LIFO
    assert_equal true, s.context["released"]
    assert_equal ["ch_5"], s.context["refunded"]
  end

  test "fail! discards staged publishes from the failing block" do
    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "d1", order_id: 6, shipment_ref: "S", total: 9)
      SagaForge.publish(:payment_failed, event_id: "d2", order_id: 6, code: "x")
    end
    failing_event = SagaForge::Event.find_by(event_name: "payment_failed", correlation_id: "6")
    assert_equal 0, SagaForge::Event.where("event_id LIKE ?", "staged:#{failing_event.id}:%").count
  end

  test "fail! with empty compensation ledger terminates :compensated with reason" do
    perform_enqueued_jobs { SagaForge.publish(:doomed, event_id: "e1", id: 1) }
    s = FailFastSaga.find_by_correlation(1)
    assert_equal "compensated", s.current_state
    assert_equal "no", s.context.dig("__saga_forge", "failure_reason")
    assert_empty(s.context.dig("__saga_forge", "compensated") || [])
  end

  test "stay loop owes one compensation run with full accumulated context" do
    perform_enqueued_jobs do
      SagaForge.publish(:pack_started, event_id: "p0", box_id: 1)
      3.times { |i| SagaForge.publish(:item_packed, event_id: "p#{i + 1}", box_id: 1) }
      SagaForge.publish(:audit_failed, event_id: "p9", box_id: 1)
    end
    s = PackSaga.find_by_correlation(1)
    assert_equal "compensated", s.current_state
    assert_equal 3, s.context["items"]
    assert_equal 1, s.context["unpack_runs"]
  end

  test "compensation retries tolerantly then records comp_error and stays compensating" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:broken_started, event_id: "b1", id: 1)
      SagaForge.publish(:broken_go, event_id: "b2", id: 1)
    end
    s = BrokenCompSaga.find_by_correlation(1)
    assert_equal "compensating", s.current_state

    outcome, wait = SagaForge::CompensationRunner.new(s.reload).call
    assert_equal :retry, outcome
    assert wait.to_f.positive?
    assert_equal 1, s.reload.context.dig("__saga_forge", "comp_attempts", "explode")

    # Minitest 6 dropped Object#stub (minitest/mock is no longer bundled), so
    # swap the class method directly and restore it after — same intent as
    # `stub`: force compensation_default down to 1 attempt so the very next
    # failure exhausts retries.
    original = SagaForge::RetryPolicy.method(:compensation_default)
    SagaForge::RetryPolicy.define_singleton_method(:compensation_default) { SagaForge::RetryPolicy.new(max_attempts: 1) }
    begin
      outcome, = SagaForge::CompensationRunner.new(s.reload).call
      assert_equal :done, outcome
    ensure
      SagaForge::RetryPolicy.define_singleton_method(:compensation_default, original)
    end
    s.reload
    assert_equal "compensating", s.current_state
    assert_equal "explode", s.context.dig("__saga_forge", "comp_error", "name")
  end

  test "crash-resume skips completed compensations (derived minus done)" do
    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "r1", order_id: 77, shipment_ref: "S", total: 2)
      SagaForge.publish(:payment_settled, event_id: "r2", order_id: 77)
    end
    s = OrderSaga.find_by_correlation(77)
    # Simulate: fail! happened and release_stock already ran, then a crash.
    ctx = s.context.deep_dup
    ctx["__saga_forge"] = {"target" => "compensated", "compensated" => ["release_stock"]}
    s.update!(current_state: "compensating", context: ctx, version: s.version + 1)

    SagaForge::CompensationRunner.new(s.reload).call
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal %w[release_stock refund], s.context.dig("__saga_forge", "compensated")
    assert s.context["refunded"].present?    # refund ran
    assert_nil s.context["released"]         # release_stock did NOT re-run
  end

  test "the execution guard covers compensation blocks too — SagaForge.publish still raises" do
    assert_raises(SagaForge::UnstagedPublishError) do
      SagaForge.guarding_execution { SagaForge.publish(:lifo_order_placed, event_id: "guard1", order_id: 999) }
    end
  end

  test "compensation blocks can publish; staged rows deliver after their commit" do
    perform_enqueued_jobs do
      SagaForge.publish(:nc_started, event_id: "n1", id: 3)
      SagaForge.publish(:nc_fail, event_id: "n2", id: 3)
    end
    s = NotifyCompSaga.find_by_correlation(3)
    assert_equal "compensated", s.current_state
    listener = FulfillmentListenerSaga.find_by_correlation("nc-3")
    assert listener, "compensation-staged publish should have delivered"
  end
end

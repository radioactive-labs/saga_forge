require "test_helper"

class CompensationTest < SagaForge::TestCase
  test "fail! compensates processed steps LIFO and lands in :compensated" do
    perform_enqueued_jobs do
      SagaForge.publish(:lifo_order_placed, order_id: 5, total: 9)
      SagaForge.publish(:lifo_payment_settled, order_id: 5)
      SagaForge.publish(:lifo_payment_failed, order_id: 5, code: "card_declined")
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
      SagaForge.publish(:order_placed, order_id: 6, shipment_ref: "S", total: 9)
      SagaForge.publish(:payment_failed, order_id: 6, code: "x")
    end
    # payment_failed's handler fails before ever reaching payment_settled's
    # `saga.publish :order_fulfilled` — so no order_fulfilled row for order 6
    # should exist, structurally identified by (saga_class, correlation_id,
    # event_name) rather than a synthetic staged event_id.
    assert_equal 0, SagaForge::Event.where(saga_class: "FulfillmentListenerSaga", correlation_id: "6", event_name: "order_fulfilled").count
  end

  test "fail! with empty compensation ledger terminates :compensated with reason" do
    perform_enqueued_jobs { SagaForge.publish(:doomed, id: 1) }
    s = FailFastSaga.find_by_correlation(1)
    assert_equal "compensated", s.current_state
    assert_equal "no", s.context.dig("__saga_forge", "failure_reason")
    assert_empty(s.context.dig("__saga_forge", "compensated") || [])
  end

  test "two distinct events sharing one compensation handler owe a single compensation run" do
    # Structural dedup means a saga instance handles each event name at most
    # once, so the old stay-loop ("N item_packed -> one unpack") no longer
    # exists. The equivalent coverage now: TWO DIFFERENT events (item_packed,
    # box_sealed) each declare compensate: :unpack, so once both have
    # processed, CompensationRunner#next_owed (which dedups the derived
    # ledger by compensation name) must still owe exactly one :unpack run.
    perform_enqueued_jobs do
      SagaForge.publish(:pack_started, box_id: 1)
      SagaForge.publish(:item_packed, box_id: 1) # -> :sealing, compensate: :unpack
      SagaForge.publish(:box_sealed, box_id: 1) # -> :packed, compensate: :unpack (same handler)
    end
    s = PackSaga.find_by_correlation(1)
    assert_equal "packed", s.current_state
    assert_equal 1, s.context["items"]
    assert_equal true, s.context["sealed"]

    # Both forward steps already committed as :processed events; force the
    # compensating handoff directly (same pattern as "crash-resume skips
    # completed compensations" above) rather than through a forward fail!,
    # since :packed is terminal and there is no more forward event to fail on.
    s.update!(current_state: "compensating", version: s.version + 1)
    SagaForge::CompensationRunner.new(s.reload).call
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal 1, s.context["unpack_runs"]
  end

  test "compensation retries tolerantly then records comp_error and stays compensating" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:broken_started, id: 1)
      SagaForge.publish(:broken_go, id: 1)
    end
    s = BrokenCompSaga.find_by_correlation(1)
    assert_equal "compensating", s.current_state
    pre_failure_active_at = s.last_active_at

    outcome, wait = SagaForge::CompensationRunner.new(s.reload).call
    assert_equal :retry, outcome
    assert wait.to_f.positive?
    s.reload
    assert_equal 1, s.context.dig("__saga_forge", "comp_attempts", "explode")
    assert_not_nil s.last_active_at
    assert(pre_failure_active_at.nil? || s.last_active_at > pre_failure_active_at,
      "record_comp_error must refresh last_active_at so a legitimately-retrying compensation doesn't look stranded to the sweeper")

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
      SagaForge.publish(:order_placed, order_id: 77, shipment_ref: "S", total: 2)
      SagaForge.publish(:payment_settled, order_id: 77)
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

  test "run_one raises ConcurrencyConflict on a stale entry_version and writes nothing" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:lifo_order_placed, order_id: 51, total: 3)
      SagaForge.publish(:lifo_payment_settled, order_id: 51)
      SagaForge.publish(:lifo_payment_failed, order_id: 51, code: "x")
    end
    s = LifoOrderSaga.find_by_correlation(51)
    assert_equal "compensating", s.current_state
    context_before = s.context

    runner = SagaForge::CompensationRunner.new(s)
    definition = s.saga_definition
    stale_entry_version = s.version + 1 # deliberately does not match the real current version

    assert_raises(SagaForge::ConcurrencyConflict) do
      runner.send(:run_one, definition, :release_stock, stale_entry_version)
    end

    s.reload
    assert_equal context_before, s.context
    assert_empty(s.context.dig("__saga_forge", "compensated") || [])
  end

  test "concurrent compensation runners converge without clobbering committed progress" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:lifo_order_placed, order_id: 52, total: 3)
      SagaForge.publish(:lifo_payment_settled, order_id: 52)
      SagaForge.publish(:lifo_payment_failed, order_id: 52, code: "x")
    end
    s = LifoOrderSaga.find_by_correlation(52)
    assert_equal "compensating", s.current_state

    # Two independent workers, each with their own in-memory copy of the row —
    # simulating two CompensationJobs racing (limits_concurrency should
    # prevent this in production; this proves the fence holds even if it
    # doesn't). runner_b's first run_one call is intercepted: before it does
    # its own with_lock write, we let runner_a run to full completion (both
    # compensations + finalize). runner_b's stale pre-lock snapshot must then
    # be fenced off instead of clobbering runner_a's committed progress.
    runner_a = SagaForge::CompensationRunner.new(SagaForge::State.find(s.id))
    runner_b = SagaForge::CompensationRunner.new(SagaForge::State.find(s.id))

    ran_a = false
    original_run_one = runner_b.method(:run_one)
    runner_b.define_singleton_method(:run_one) do |*args|
      unless ran_a
        ran_a = true
        runner_a.call
      end
      original_run_one.call(*args)
    end

    runner_b.call
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal %w[release_stock refund], s.context.dig("__saga_forge", "compensated")
    assert_equal true, s.context["released"]
    assert_equal ["ch_52"], s.context["refunded"]
  end

  test "a compensation-step commit stamps last_active_at; finalize! stamps finalized_at" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:lifo_order_placed, order_id: 105, total: 3)
      SagaForge.publish(:lifo_payment_settled, order_id: 105)
      SagaForge.publish(:lifo_payment_failed, order_id: 105, code: "x")
    end
    s = LifoOrderSaga.find_by_correlation(105)
    assert_equal "compensating", s.current_state
    assert_nil s.finalized_at

    definition = s.saga_definition
    SagaForge::CompensationRunner.new(s).send(:run_one, definition, :release_stock, s.version)
    s.reload
    assert_not_nil s.last_active_at
    assert_nil s.finalized_at

    SagaForge::CompensationRunner.new(s).call
    s.reload
    assert_equal "compensated", s.current_state
    assert_not_nil s.finalized_at
  end

  test "the execution guard covers compensation blocks too — SagaForge.publish still raises" do
    assert_raises(SagaForge::UnstagedPublishError) do
      SagaForge.guarding_execution { SagaForge.publish(:lifo_order_placed, order_id: 999) }
    end
  end

  test "compensation blocks can publish; staged rows deliver after their commit" do
    perform_enqueued_jobs do
      SagaForge.publish(:nc_started, id: 3)
      SagaForge.publish(:nc_fail, id: 3)
    end
    s = NotifyCompSaga.find_by_correlation(3)
    assert_equal "compensated", s.current_state
    listener = FulfillmentListenerSaga.find_by_correlation("nc-3")
    assert listener, "compensation-staged publish should have delivered"
  end
end

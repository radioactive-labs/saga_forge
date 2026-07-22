require "test_helper"

class PublisherTest < SagaForge::TestCase
  test "broadcast: one row per registered class with each class's correlation" do
    rows = SagaForge.publish(:order_placed, order_id: 42, shipment_ref: "SHP-9", total: 5)
    assert_equal %w[OrderSaga ShipmentSaga], rows.map(&:saga_class).sort
    assert_equal "42", rows.find { |r| r.saga_class == "OrderSaga" }.correlation_id
    assert_equal "SHP-9", rows.find { |r| r.saga_class == "ShipmentSaga" }.correlation_id
    assert rows.all?(&:pending?)
    assert_enqueued_jobs 2, only: SagaForge::ExecutionJob
  end

  test "missing correlation fails whole publish atomically" do
    assert_raises(SagaForge::MissingCorrelationError) do
      SagaForge.publish(:order_placed, order_id: 42) # no shipment_ref for ShipmentSaga
    end
    assert_equal 0, SagaForge::Event.count
    assert_no_enqueued_jobs
  end

  test "duplicate delivery dedups on structural key" do
    2.times { SagaForge.publish(:order_placed, order_id: "A1", shipment_ref: "SHP-A1", total: 5) }
    rows = SagaForge::Event.where(saga_class: "OrderSaga", correlation_id: "A1", event_name: "order_placed")
    assert_equal 1, rows.count
  end

  test "publish inside execution raises UnstagedPublishError" do
    SagaForge.guarding_execution do
      assert_raises(SagaForge::UnstagedPublishError) do
        SagaForge.publish(:order_placed, order_id: 1, shipment_ref: "s")
      end
    end
    assert_equal 0, SagaForge::Event.count
  end

  test "no registered recipients is a no-op" do
    assert_equal [], SagaForge.publish(:nobody_cares, foo: 1)
    assert_no_enqueued_jobs
  end

  test "publish joins an open transaction (rollback drops rows)" do
    SagaForge::ApplicationRecord.transaction do
      SagaForge.publish(:review_passed, order_id: 9)
      raise ActiveRecord::Rollback
    end
    assert_equal 0, SagaForge::Event.where(saga_class: "OrderSaga", correlation_id: "9", event_name: "review_passed").count
  end

  # insert_row's savepoint (transaction(requires_new: true)) exists to
  # survive Postgres's abort-on-error semantics: on PG, a failed INSERT
  # poisons the whole ambient transaction, so a duplicate-delivery no-op
  # would otherwise take the caller's entire transaction down with it.
  # SQLite doesn't abort the outer transaction on a unique-constraint
  # violation, so this test can't reproduce THAT failure mode directly — but
  # it still pins the intended contract: a duplicate publish inside an
  # ambient transaction must leave that transaction usable for whatever
  # comes after it.
  test "duplicate publish inside an ambient transaction leaves the transaction usable" do
    SagaForge.publish(:review_passed, order_id: 1)

    SagaForge::ApplicationRecord.transaction do
      dup = SagaForge.publish(:review_passed, order_id: 1)
      assert_equal [], dup

      fresh = SagaForge.publish(:review_passed, order_id: 2)
      assert_equal 1, fresh.size
    end

    assert_equal 1, SagaForge::Event.where(saga_class: "OrderSaga", correlation_id: "1", event_name: "review_passed").count
    assert_equal 1, SagaForge::Event.where(saga_class: "OrderSaga", correlation_id: "2", event_name: "review_passed").count
  end
end

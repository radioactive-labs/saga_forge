require "test_helper"

class PublisherTest < SagaForge::TestCase
  test "broadcast: one row per registered class with each class's correlation" do
    rows = SagaForge.publish(:order_placed, event_id: "op:1", order_id: 42, shipment_ref: "SHP-9", total: 5)
    assert_equal %w[OrderSaga ShipmentSaga], rows.map(&:saga_class).sort
    assert_equal "42", rows.find { |r| r.saga_class == "OrderSaga" }.correlation_id
    assert_equal "SHP-9", rows.find { |r| r.saga_class == "ShipmentSaga" }.correlation_id
    assert rows.all?(&:pending?)
    assert_enqueued_jobs 2, only: SagaForge::ExecutionJob
  end

  test "missing correlation fails whole publish atomically" do
    assert_raises(SagaForge::MissingCorrelationError) do
      SagaForge.publish(:order_placed, event_id: "op:2", order_id: 42) # no shipment_ref for ShipmentSaga
    end
    assert_equal 0, SagaForge::Event.count
    assert_no_enqueued_jobs
  end

  test "event_id dedup no-ops duplicates" do
    first = SagaForge.publish(:review_passed, event_id: "rv:1", order_id: 1)
    assert_equal 1, first.size
    assert_no_difference -> { SagaForge::Event.count } do
      dup = SagaForge.publish(:review_passed, event_id: "rv:1", order_id: 1)
      assert_equal [], dup
    end
  end

  test "digest fallback is deterministic and key-order independent" do
    a = SagaForge::Publisher.digest_id(:x, {b: 1, a: [1, 2]})
    b = SagaForge::Publisher.digest_id(:x, {a: [1, 2], b: 1})
    assert_equal a, b
    refute_equal a, SagaForge::Publisher.digest_id(:x, {b: 2, a: [1, 2]})
  end

  test "publish without event_id uses digest and still dedups" do
    SagaForge.publish(:review_passed, order_id: 7)
    assert_no_difference -> { SagaForge::Event.count } do
      SagaForge.publish(:review_passed, order_id: 7)
    end
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
    assert_equal [], SagaForge.publish(:nobody_cares, event_id: "n:1", foo: 1)
    assert_no_enqueued_jobs
  end

  test "publish joins an open transaction (rollback drops rows)" do
    SagaForge::ApplicationRecord.transaction do
      SagaForge.publish(:review_passed, event_id: "tx:1", order_id: 9)
      raise ActiveRecord::Rollback
    end
    assert_equal 0, SagaForge::Event.where(event_id: "tx:1").count
  end
end

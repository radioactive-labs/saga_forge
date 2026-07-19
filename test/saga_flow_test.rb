require "test_helper"

class SagaFlowTest < SagaForge::TestCase
  test "full happy chain via enqueued jobs; out-of-order arrival heals via parking" do
    SagaForge.configure { |c| c.stall_budget = 1 } # park immediately
    perform_enqueued_jobs do
      SagaForge.publish(:review_passed, event_id: "e3", order_id: 1) # early — parks
    end
    assert SagaForge::Event.find_by(event_name: "review_passed").stalled?

    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "e1", order_id: 1, shipment_ref: "S1", total: 10)
      SagaForge.publish(:payment_settled, event_id: "e2", order_id: 1)
    end
    state = OrderSaga.find_by_correlation(1)
    assert_equal "completed", state.current_state
    assert_equal %w[processed processed processed],
      state.events.ledger_order.map(&:status)
  end
end

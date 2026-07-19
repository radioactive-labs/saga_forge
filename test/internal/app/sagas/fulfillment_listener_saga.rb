class FulfillmentListenerSaga < SagaForge::Base
  correlate_by :order_id

  start_with(:order_fulfilled) { |saga, _payload| saga.context[:notified] = true }

  finish_with :notified
end

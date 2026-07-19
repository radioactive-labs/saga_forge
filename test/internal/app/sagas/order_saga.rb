class OrderSaga < SagaForge::Base
  correlate_by :order_id

  start_with :order_placed, compensate: :refund do |saga, payload|
    saga.context[:total] = payload[:total]
    saga.context[:charges] = (saga.context[:charges] || []) << "ch_#{saga.correlation_id}"
  end

  during :awaiting_settlement, on: :payment_settled, compensate: :release_stock do |saga, _payload|
    saga.context[:reserved] = true
    saga.publish :order_fulfilled, order_id: saga.correlation_id
  end

  during :awaiting_settlement, on: :payment_failed do |saga, payload|
    saga.fail! reason: payload[:code]
  end

  during :awaiting_review, on: :review_passed do |saga, _payload|
    saga.transition_to :completed if saga.context[:total].to_i > 0
  end

  finish_with :completed

  compensation :refund do |saga|
    next unless saga.context[:charges]
    saga.context[:refunded] = saga.context[:charges].dup
  end

  compensation :release_stock do |saga|
    saga.context[:released] = true
  end
end

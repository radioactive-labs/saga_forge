# Same shape as OrderSaga's happy path, but payment_settled and payment_failed
# are NOT alternative branches off one state (OrderSaga's pattern): here
# payment_failed is registered at the state payment_settled falls through to,
# so a saga can legitimately process order_placed -> payment_settled ->
# payment_failed in sequence. Exists so CompensationTest can exercise LIFO
# ordering across two DISTINCT owed compensations without disturbing
# OrderSaga's existing branching-based coverage elsewhere.
class LifoOrderSaga < SagaForge::Base
  correlate_by :order_id

  start_with(:lifo_order_placed, compensate: :refund) do |saga, payload|
    saga.context[:total] = payload[:total]
    saga.context[:charges] = (saga.context[:charges] || []) << "ch_#{saga.correlation_id}"
  end

  during(:awaiting_settlement, on: :lifo_payment_settled, compensate: :release_stock) do |saga, _payload|
    saga.context[:reserved] = true
  end

  during(:awaiting_review, on: :lifo_payment_failed) do |saga, payload|
    saga.fail! reason: payload[:code]
  end

  finish_with :completed

  compensation(:refund) do |saga|
    next unless saga.context[:charges]
    saga.context[:refunded] = saga.context[:charges].dup
  end

  compensation(:release_stock) do |saga|
    saga.context[:released] = true
  end
end

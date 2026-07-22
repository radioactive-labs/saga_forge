# Mirrors the core gem's OrderSaga shape (test/internal/app/sagas/order_saga.rb
# there), with a second :awaiting_review handler so the dashboard's graph
# fixtures exercise both edge kinds: chain (start -> awaiting_settlement ->
# awaiting_review -> completed) and jump (awaiting_review -> completed via
# transition_to, from either :review_passed or :more_info_needed). Sagas are
# forward-only now, so :more_info_needed advances instead of looping.
class OrderSaga < SagaForge::Base
  correlate_by :order_id

  start_with :order_placed, compensate: :refund do |saga, payload|
    saga.context[:total] = payload[:total]
  end

  during :awaiting_settlement, on: :payment_settled, compensate: :release_stock do |saga, _payload|
    saga.context[:reserved] = true
  end

  during :awaiting_settlement, on: :payment_failed do |saga, payload|
    saga.fail! reason: payload[:code]
  end

  during :awaiting_review, on: :review_passed do |saga, _payload|
    saga.transition_to :completed if saga.context[:total].to_i > 0
  end

  during :awaiting_review, on: :more_info_needed do |saga, _payload|
    saga.transition_to :completed
  end

  finish_with :completed

  compensation :refund do |saga|
    saga.context[:refunded] = true
  end

  compensation :release_stock do |saga|
    saga.context[:released] = true
  end
end

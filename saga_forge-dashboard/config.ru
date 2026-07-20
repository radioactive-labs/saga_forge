# Dev-only boot for driving the dashboard in a browser. Not part of the gem.
ENV["RAILS_ENV"] ||= "test"

require "active_job/railtie"
require "saga_forge/dashboard"
require "combustion"

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job, :action_controller

SagaForge::Dashboard.configure do |c|
  c.authentication = :none
  c.polling_interval = 0 # stable for screenshots
end

S = SagaForge::State
E = SagaForge::Event

# Events reference states with no on-delete action, so clear the ledger first.
E.delete_all
S.delete_all

# --- DemoSaga -----------------------------------------------------------
# demo_started -> demo_waiting (on: demo_done) -> demo_complete
# No compensations declared, so DemoSaga never appears compensating below;
# OrderSaga (which declares refund/release_stock) carries that story.

# Running: kicked off, waiting on its next event.
demo_running = S.create!(saga_class: "DemoSaga", correlation_id: "demo-101",
  current_state: "demo_waiting", context: {started: true},
  created_at: 45.minutes.ago, updated_at: 45.minutes.ago)
E.create!(event_id: "demo-101-started", saga_class: "DemoSaga", correlation_id: "demo-101",
  state: demo_running, event_name: "demo_started", status: :processed,
  payload: {}, created_at: 45.minutes.ago, updated_at: 45.minutes.ago)

# Stalled: demo_done parked after exhausting its stall budget.
demo_stalled = S.create!(saga_class: "DemoSaga", correlation_id: "demo-201",
  current_state: "demo_waiting", context: {started: true},
  created_at: 2.hours.ago, updated_at: 90.minutes.ago)
E.create!(event_id: "demo-201-started", saga_class: "DemoSaga", correlation_id: "demo-201",
  state: demo_stalled, event_name: "demo_started", status: :processed,
  payload: {}, created_at: 2.hours.ago, updated_at: 2.hours.ago)
E.create!(event_id: "demo-201-done", saga_class: "DemoSaga", correlation_id: "demo-201",
  state: demo_stalled, event_name: "demo_done", status: :stalled, stall_count: 40,
  payload: {}, created_at: 100.minutes.ago, updated_at: 90.minutes.ago)

# Suspended: demo_done raised and exhausted its retries.
demo_suspended = S.create!(saga_class: "DemoSaga", correlation_id: "demo-301",
  current_state: "demo_waiting", context: {started: true},
  created_at: 3.hours.ago, updated_at: 2.hours.ago)
E.create!(event_id: "demo-301-started", saga_class: "DemoSaga", correlation_id: "demo-301",
  state: demo_suspended, event_name: "demo_started", status: :processed,
  payload: {}, created_at: 3.hours.ago, updated_at: 3.hours.ago)
E.create!(event_id: "demo-301-done", saga_class: "DemoSaga", correlation_id: "demo-301",
  state: demo_suspended, event_name: "demo_done", status: :failed, attempts: 3,
  payload: {}, error: {"class" => "RuntimeError", "message" => "undefined method `complete!' for nil",
    "backtrace" => ["app/sagas/demo_saga.rb:4:in `block in <class:DemoSaga>'",
      "lib/saga_forge/execution/runner.rb:58:in `call'"]},
  created_at: 2.hours.ago, updated_at: 2.hours.ago)

# Completed.
demo_completed = S.create!(saga_class: "DemoSaga", correlation_id: "demo-401",
  current_state: "demo_complete", context: {started: true},
  created_at: 1.day.ago, updated_at: 23.hours.ago)
E.create!(event_id: "demo-401-started", saga_class: "DemoSaga", correlation_id: "demo-401",
  state: demo_completed, event_name: "demo_started", status: :processed,
  payload: {}, created_at: 1.day.ago, updated_at: 1.day.ago)
E.create!(event_id: "demo-401-done", saga_class: "DemoSaga", correlation_id: "demo-401",
  state: demo_completed, event_name: "demo_done", status: :processed,
  payload: {}, created_at: 23.hours.ago, updated_at: 23.hours.ago)

# Cancelled by an operator before it ever reached demo_done.
demo_cancelled = S.create!(saga_class: "DemoSaga", correlation_id: "demo-501",
  current_state: "cancelled",
  context: {started: true, "__saga_forge" => {"target" => "cancelled", "compensated" => [],
    "failure_reason" => "operator cancelled: duplicate signup"}},
  created_at: 4.hours.ago, updated_at: 3.hours.ago)
E.create!(event_id: "demo-501-started", saga_class: "DemoSaga", correlation_id: "demo-501",
  state: demo_cancelled, event_name: "demo_started", status: :processed,
  payload: {}, created_at: 4.hours.ago, updated_at: 4.hours.ago)

# --- OrderSaga ------------------------------------------------------------
# order_placed (compensate: refund) -> awaiting_settlement (payment_settled,
# compensate: release_stock / payment_failed -> fail!) -> awaiting_review
# (review_passed -> jump completed / more_info_needed -> stay) -> completed

# Running: payment not yet settled.
order_running1 = S.create!(saga_class: "OrderSaga", correlation_id: "order-1001",
  current_state: "awaiting_settlement", context: {total: 4999},
  created_at: 30.minutes.ago, updated_at: 30.minutes.ago)
E.create!(event_id: "order-1001-placed", saga_class: "OrderSaga", correlation_id: "order-1001",
  state: order_running1, event_name: "order_placed", status: :processed,
  payload: {total: 4999}, created_at: 30.minutes.ago, updated_at: 30.minutes.ago)

# Running: further along, looped once on more_info_needed (a `stay` edge) before
# settling into awaiting_review, so the timeline shows a real revisit.
order_running2 = S.create!(saga_class: "OrderSaga", correlation_id: "order-1002",
  current_state: "awaiting_review", context: {total: 1200, reserved: true},
  created_at: 6.hours.ago, updated_at: 15.minutes.ago)
E.create!(event_id: "order-1002-placed", saga_class: "OrderSaga", correlation_id: "order-1002",
  state: order_running2, event_name: "order_placed", status: :processed,
  payload: {total: 1200}, created_at: 6.hours.ago, updated_at: 6.hours.ago)
E.create!(event_id: "order-1002-settled", saga_class: "OrderSaga", correlation_id: "order-1002",
  state: order_running2, event_name: "payment_settled", status: :processed,
  payload: {}, created_at: 5.hours.ago, updated_at: 5.hours.ago)
E.create!(event_id: "order-1002-more-info", saga_class: "OrderSaga", correlation_id: "order-1002",
  state: order_running2, event_name: "more_info_needed", status: :processed,
  payload: {reason: "address mismatch"}, created_at: 15.minutes.ago, updated_at: 15.minutes.ago)

# Stalled: the settlement webhook parked waiting for order_placed to commit.
order_stalled1 = S.create!(saga_class: "OrderSaga", correlation_id: "order-2001",
  current_state: "awaiting_settlement", context: {total: 7500},
  created_at: 90.minutes.ago, updated_at: 40.minutes.ago)
E.create!(event_id: "order-2001-placed", saga_class: "OrderSaga", correlation_id: "order-2001",
  state: order_stalled1, event_name: "order_placed", status: :processed,
  payload: {total: 7500}, created_at: 90.minutes.ago, updated_at: 90.minutes.ago)
E.create!(event_id: "order-2001-settled", saga_class: "OrderSaga", correlation_id: "order-2001",
  state: order_stalled1, event_name: "payment_settled", status: :stalled, stall_count: 40,
  payload: {}, created_at: 50.minutes.ago, updated_at: 40.minutes.ago)

# Stalled: a review outcome parked behind a slow reviewer queue.
order_stalled2 = S.create!(saga_class: "OrderSaga", correlation_id: "order-2002",
  current_state: "awaiting_review", context: {total: 300, reserved: true},
  created_at: 2.days.ago, updated_at: 20.minutes.ago)
E.create!(event_id: "order-2002-placed", saga_class: "OrderSaga", correlation_id: "order-2002",
  state: order_stalled2, event_name: "order_placed", status: :processed,
  payload: {total: 300}, created_at: 2.days.ago, updated_at: 2.days.ago)
E.create!(event_id: "order-2002-settled", saga_class: "OrderSaga", correlation_id: "order-2002",
  state: order_stalled2, event_name: "payment_settled", status: :processed,
  payload: {}, created_at: 2.days.ago, updated_at: 2.days.ago)
E.create!(event_id: "order-2002-review", saga_class: "OrderSaga", correlation_id: "order-2002",
  state: order_stalled2, event_name: "review_passed", status: :stalled, stall_count: 15,
  payload: {}, created_at: 30.minutes.ago, updated_at: 20.minutes.ago)

# Suspended: the settlement webhook handler raised and exhausted its retries.
order_suspended = S.create!(saga_class: "OrderSaga", correlation_id: "order-3001",
  current_state: "awaiting_settlement", context: {total: 12000},
  created_at: 2.hours.ago, updated_at: 1.hour.ago)
E.create!(event_id: "order-3001-placed", saga_class: "OrderSaga", correlation_id: "order-3001",
  state: order_suspended, event_name: "order_placed", status: :processed,
  payload: {total: 12000}, created_at: 2.hours.ago, updated_at: 2.hours.ago)
E.create!(event_id: "order-3001-settled", saga_class: "OrderSaga", correlation_id: "order-3001",
  state: order_suspended, event_name: "payment_settled", status: :failed, attempts: 3,
  payload: {}, error: {"class" => "Gateway::TimeoutError", "message" => "settlement webhook timed out after 30s",
    "backtrace" => ["app/services/gateway.rb:61:in `confirm!'",
      "app/sagas/order_saga.rb:12:in `block in <class:OrderSaga>'"]},
  created_at: 1.hour.ago, updated_at: 1.hour.ago)

# Completed: took the review_passed jump straight to :completed.
order_completed = S.create!(saga_class: "OrderSaga", correlation_id: "order-4001",
  current_state: "completed", context: {total: 2500, reserved: true},
  created_at: 1.day.ago, updated_at: 20.hours.ago)
E.create!(event_id: "order-4001-placed", saga_class: "OrderSaga", correlation_id: "order-4001",
  state: order_completed, event_name: "order_placed", status: :processed,
  payload: {total: 2500}, created_at: 1.day.ago, updated_at: 1.day.ago)
E.create!(event_id: "order-4001-settled", saga_class: "OrderSaga", correlation_id: "order-4001",
  state: order_completed, event_name: "payment_settled", status: :processed,
  payload: {}, created_at: 22.hours.ago, updated_at: 22.hours.ago)
E.create!(event_id: "order-4001-review", saga_class: "OrderSaga", correlation_id: "order-4001",
  state: order_completed, event_name: "review_passed", status: :processed,
  payload: {}, created_at: 20.hours.ago, updated_at: 20.hours.ago)

# Compensating: payment_failed triggered a rollback; release_stock has already
# run, refund is still owed (owed order is LIFO: release_stock, then refund).
order_compensating = S.create!(saga_class: "OrderSaga", correlation_id: "order-5001",
  current_state: "compensating",
  context: {total: 8000, reserved: true, "__saga_forge" => {"target" => "compensated",
    "compensated" => ["release_stock"], "failure_reason" => "card_declined"}},
  created_at: 50.minutes.ago, updated_at: 5.minutes.ago)
E.create!(event_id: "order-5001-placed", saga_class: "OrderSaga", correlation_id: "order-5001",
  state: order_compensating, event_name: "order_placed", status: :processed,
  payload: {total: 8000}, created_at: 50.minutes.ago, updated_at: 50.minutes.ago)
E.create!(event_id: "order-5001-settled", saga_class: "OrderSaga", correlation_id: "order-5001",
  state: order_compensating, event_name: "payment_settled", status: :processed,
  payload: {}, created_at: 40.minutes.ago, updated_at: 40.minutes.ago)
E.create!(event_id: "order-5001-failed", saga_class: "OrderSaga", correlation_id: "order-5001",
  state: order_compensating, event_name: "payment_failed", status: :processed,
  payload: {code: "card_declined"}, created_at: 10.minutes.ago, updated_at: 10.minutes.ago)

# Stuck compensating: release_stock is done, but refund has exhausted its
# retries mid-rollback (comp_error present) and needs an operator's attention.
order_stuck = S.create!(saga_class: "OrderSaga", correlation_id: "order-6001",
  current_state: "compensating",
  context: {total: 15000, reserved: true, "__saga_forge" => {"target" => "compensated",
    "compensated" => ["release_stock"], "comp_attempts" => {"refund" => 10},
    "failure_reason" => "card_declined",
    "comp_error" => {"name" => "refund", "class" => "PaymentGateway::RefundError",
      "message" => "refund failed: original charge not found"}}},
  created_at: 3.hours.ago, updated_at: 30.minutes.ago)
E.create!(event_id: "order-6001-placed", saga_class: "OrderSaga", correlation_id: "order-6001",
  state: order_stuck, event_name: "order_placed", status: :processed,
  payload: {total: 15000}, created_at: 3.hours.ago, updated_at: 3.hours.ago)
E.create!(event_id: "order-6001-settled", saga_class: "OrderSaga", correlation_id: "order-6001",
  state: order_stuck, event_name: "payment_settled", status: :processed,
  payload: {}, created_at: 2.hours.ago, updated_at: 2.hours.ago)
E.create!(event_id: "order-6001-failed", saga_class: "OrderSaga", correlation_id: "order-6001",
  state: order_stuck, event_name: "payment_failed", status: :processed,
  payload: {code: "card_declined"}, created_at: 90.minutes.ago, updated_at: 90.minutes.ago)

# Cancelled by an operator; refund had already run before the cancel landed.
order_cancelled = S.create!(saga_class: "OrderSaga", correlation_id: "order-7001",
  current_state: "cancelled",
  context: {total: 500, "__saga_forge" => {"target" => "cancelled", "compensated" => ["refund"],
    "failure_reason" => "customer requested cancellation"}},
  created_at: 5.hours.ago, updated_at: 4.hours.ago)
E.create!(event_id: "order-7001-placed", saga_class: "OrderSaga", correlation_id: "order-7001",
  state: order_cancelled, event_name: "order_placed", status: :processed,
  payload: {total: 500}, created_at: 5.hours.ago, updated_at: 5.hours.ago)

run Combustion::Application

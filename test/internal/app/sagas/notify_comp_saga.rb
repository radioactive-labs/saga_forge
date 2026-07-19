class NotifyCompSaga < SagaForge::Base
  correlate_by :id
  start_with(:nc_started, compensate: :nc_undo) { |saga, _payload| saga.context[:go] = true }
  during(:nc_waiting, on: :nc_fail) { |saga, _payload| saga.fail! reason: "nc" }
  finish_with :nc_done
  compensation(:nc_undo) do |saga|
    saga.publish :order_fulfilled, order_id: "nc-#{saga.correlation_id}"
  end
end

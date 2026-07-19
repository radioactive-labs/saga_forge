class ShipmentSaga < SagaForge::Base
  correlate_by { |p, _event| p[:shipment_ref] }
  start_with(:order_placed) { |saga, _payload| }
  finish_with :shipped
end

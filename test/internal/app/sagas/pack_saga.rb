class PackSaga < SagaForge::Base
  correlate_by :box_id
  start_with(:pack_started) { |saga, _payload| saga.context[:items] = 0 }
  during(:packing, on: :item_packed, compensate: :unpack) do |saga, _payload|
    saga.context[:items] = saga.context[:items].to_i + 1
  end
  during(:sealing, on: :box_sealed, compensate: :unpack) { |saga, _payload| saga.context[:sealed] = true }
  during(:packing, on: :audit_failed) { |saga, _payload| saga.fail! reason: "audit" }
  finish_with :packed
  compensation(:unpack) { |saga| saga.context[:unpack_runs] = saga.context[:unpack_runs].to_i + 1 }
end

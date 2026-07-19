module SagaForge
  # The ledger: inbound rows only, append-only, mutable status.
  class Event < ApplicationRecord
    self.table_name = "saga_forge_events"

    belongs_to :state, class_name: "SagaForge::State",
      foreign_key: :saga_forge_state_id, optional: true

    enum :status, {pending: 0, processed: 1, stalled: 2, failed: 3}

    scope :for_instance, ->(saga_class, correlation_id) {
      where(saga_class: saga_class.to_s, correlation_id: correlation_id.to_s)
    }
    scope :ledger_order, -> { order(:created_at, :id) }
  end
end

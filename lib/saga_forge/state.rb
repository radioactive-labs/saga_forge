module SagaForge
  # The saga's ground truth, and only the truth. current_state is always the
  # real workflow position; stalls/failures live on Event rows.
  class State < ApplicationRecord
    self.table_name = "saga_forge_states"

    COMPENSATING = :compensating
    COMPENSATED = :compensated
    CANCELLED = :cancelled

    has_many :events, class_name: "SagaForge::Event",
      foreign_key: :saga_forge_state_id, dependent: nil

    scope :for_saga, ->(klass) { where(saga_class: klass.to_s) }
    scope :in_state, ->(state) { where(current_state: state.to_s) }
    scope :stalled, -> { where(id: Event.stalled.select(:saga_forge_state_id)) }
    scope :suspended, -> { where(id: Event.failed.select(:saga_forge_state_id)) }

    def history = events.ledger_order

    def saga_definition = saga_class.constantize.definition
  end
end

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

    def retry_stalled!
      events.stalled.ledger_order.each do |event|
        event.update!(status: :pending, stall_count: 0)
        ExecutionJob.perform_later(event.id)
      end
    end

    def resume!
      events.failed.ledger_order.each do |event|
        event.update!(status: :pending, attempts: 0, retry_budgets: {}, error: nil)
        ExecutionJob.perform_later(event.id)
      end
    end

    # Resume-then-compensate (§A.4): a failed step's side effects may have
    # happened, but its event never processed and its context never committed —
    # so it implies no compensation and its compensation's guard sees nothing.
    # Fix the code, resume!, then compensate if still desired.
    #
    # Returns true if this call actually transitioned the saga into
    # :compensating, false on a no-op (already terminal/compensating) — a
    # small deliberate API nicety for the dashboard phase.
    def compensate!(target: COMPENSATED, reason: nil)
      if events.failed.exists?
        Rails.logger.warn do
          "[saga_forge] compensate! on #{saga_class}##{correlation_id} with failed events — " \
            "failed steps imply no compensation and left no context; resume!, then compensate"
        end
      end

      transitioned = false
      with_lock do
        break if saga_definition.terminal?(current_state) || current_state == COMPENSATING.to_s

        context_copy = context.deep_dup
        meta = (context_copy["__saga_forge"] || {}).merge("target" => target.to_s)
        meta["failure_reason"] = reason if reason
        context_copy["__saga_forge"] = meta
        update!(current_state: COMPENSATING.to_s, version: version + 1, context: context_copy)
        transitioned = true
      end
      CompensationJob.perform_later(id) if transitioned
      transitioned
    end

    def cancel!(reason:)
      compensate!(target: CANCELLED, reason: reason)
    end
  end
end

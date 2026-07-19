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

    # Status-scoped: the UPDATE only touches rows still :stalled, so a
    # concurrent redeliver_parked landing a row on :processed between our
    # SELECT and this write can never be regressed back to :pending (a step
    # is compensable iff it committed — Task 8's invariant). Enqueueing an id
    # that raced ahead to :processed is harmless (ExecutionJob/Runner no-op
    # on an already-processed row).
    def retry_stalled!
      if recovery_blocked?
        Rails.logger.warn { "[saga_forge] retry_stalled! no-op on #{saga_class}##{correlation_id}: saga is #{current_state}" }
        return false
      end

      ids = events.stalled.ledger_order.ids
      count = Event.where(id: ids, status: :stalled)
        .update_all(status: :pending, stall_count: 0, updated_at: Time.current)
      enqueue_execution(ids)
      count > 0
    end

    # Same status-scoping as retry_stalled! — see there.
    def resume!
      if recovery_blocked?
        Rails.logger.warn { "[saga_forge] resume! no-op on #{saga_class}##{correlation_id}: saga is #{current_state}" }
        return false
      end

      ids = events.failed.ledger_order.ids
      count = Event.where(id: ids, status: :failed)
        .update_all(status: :pending, attempts: 0, retry_budgets: {}, error: nil, updated_at: Time.current)
      enqueue_execution(ids)
      count > 0
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
      if !recovery_blocked? && events.failed.exists?
        Rails.logger.warn do
          "[saga_forge] compensate! on #{saga_class}##{correlation_id} with failed events — " \
            "failed steps imply no compensation and left no context; resume!, then compensate"
        end
      end

      transitioned = false
      with_lock do
        break if recovery_blocked?

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

    private

    # Terminal or already-compensating: resuming/retrying a parked event here
    # would orphan it forever (no future state transition will ever redeliver
    # it — §A.3's redelivery only fires for the saga's live current_state).
    def recovery_blocked?
      saga_definition.terminal?(current_state) || current_state == COMPENSATING.to_s
    end

    # ActiveJob.perform_all_later (Rails 7.1+) enqueues in one batch instead
    # of N; the :test adapter has no #enqueue_all so it transparently falls
    # back to per-job #enqueue/#enqueue_at in the same order — verified
    # empirically to behave identically to a bare .each { perform_later }
    # under perform_enqueued_jobs/assert_enqueued_jobs.
    def enqueue_execution(ids)
      return if ids.empty?
      ActiveJob.perform_all_later(ids.map { |id| ExecutionJob.new(id) })
    end
  end
end

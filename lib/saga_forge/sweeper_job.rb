module SagaForge
  # The delivery guarantee (§A.2): rows are obligations, enqueues are hints.
  # Sweeps three stranded populations; harmless double-enqueues are absorbed
  # by ExecutionJob's processed-skip/halt/stall checks. Host-scheduled
  # (config/recurring.yml) at config.sweep_interval cadence.
  class SweeperJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    # A fixed singleton key, not per-instance: this is one recurring job, not
    # one lock per saga — an over-long sweep must not overlap the next tick.
    # See ExecutionJob::CONCURRENCY_KEY for why this is a constant.
    CONCURRENCY_KEY = "SagaForge::Sweeper"

    if defined?(SolidQueue)
      limits_concurrency key: CONCURRENCY_KEY
    end

    def perform
      sweep_aged_pending
      sweep_stranded_compensating
      sweep_stranded_stalled
    end

    private

    def cutoff = SagaForge.config.sweep_interval.ago

    def sweep_aged_pending
      Event.pending.where(created_at: ..cutoff).find_each do |event|
        ExecutionJob.perform_later(event.id)
      end
    end

    # A fail!/compensate! handoff is a once-only hint (Task 6 review): a crash
    # between the commit and the CompensationJob enqueue strands the saga in
    # :compensating. Exhausted compensations (comp_error present) are
    # operator-recovery-only — re-enqueueing them would re-run a broken block
    # every sweep, forever.
    def sweep_stranded_compensating
      State.in_state(State::COMPENSATING).where(updated_at: ..cutoff).find_each do |state|
        next if state.context.dig("__saga_forge", "comp_error").present?
        CompensationJob.perform_later(state.id)
      end
    end

    # A crash between a commit and redeliver_parked strands a parked event the
    # saga is now waiting on (Task 6 review): no future commit will advance the
    # saga, so nothing else will ever re-deliver it.
    #
    # group_by loads all aged stalled events into memory to compile each
    # saga_class's Definition once — acceptable at expected stalled volumes
    # (crash-induced strandings are rare and self-limiting); switch to
    # in_batches per saga_class if that stops being true.
    def sweep_stranded_stalled
      Event.stalled.where(updated_at: ..cutoff).group_by(&:saga_class).each do |saga_class, events|
        klass = saga_class.safe_constantize
        unless klass
          Rails.logger.error { "[saga_forge] sweeper: #{saga_class} no longer exists; #{events.size} stalled event(s) unrecoverable" }
          next
        end
        definition = klass.definition
        states = State.where(saga_class: saga_class, correlation_id: events.map(&:correlation_id).uniq)
          .index_by(&:correlation_id)
        # Ledger order (§A.3) among the events already loaded in memory —
        # re-delivery must honor the same ordering a live redeliver_parked would.
        events.sort_by { |e| [e.created_at, e.id] }.each do |event|
          state = states[event.correlation_id]
          next unless state
          next unless definition.state_for_event(event.event_name)&.to_s == state.current_state
          # Status-scoped for the same reason as PostCommit#redeliver_parked:
          # this event was loaded minutes ago (cutoff-aged); a live commit may
          # have already processed it by the time the sweep gets here.
          updated = Event.where(id: event.id, status: :stalled)
            .update_all(status: :pending, stall_count: 0, updated_at: Time.current)
          ExecutionJob.perform_later(event.id) if updated > 0
        end
      end
    end
  end
end

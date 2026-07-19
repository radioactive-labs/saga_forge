module SagaForge
  # Rollback is derived, not stored (§A.4): owed = processed events, mapped
  # through the compensate: registry, deduped, run LIFO with a commit per
  # compensation. Progress lives in context["__saga_forge"]. A saga stuck in
  # :compensating after exhausted retries is recovered by operator
  # compensate! (Task 11) or the sweeper (Task 10).
  class CompensationRunner
    COMP_ERROR_MESSAGE_LIMIT = 5_000

    attr_reader :state

    def initialize(state)
      @state = state
    end

    def call
      definition = state.saga_definition

      loop do
        state.reload
        name = next_owed(definition)
        return finalize! if name.nil?

        outcome = run_one(definition, name)
        return outcome unless outcome == :continue
      end
    end

    private

    def next_owed(definition)
      done = (state.context.dig("__saga_forge", "compensated") || []).map(&:to_s)
      owed = state.events.processed.ledger_order
        .filter_map { |e| definition.handler_for(e.event_name)&.compensate }
        .uniq
        .reverse
      owed.map(&:to_s).find { |n| !done.include?(n) }&.to_sym
    end

    def run_one(definition, name)
      block = definition.compensations.fetch(name)
      context = state.context.deep_dup.with_indifferent_access
      facade = Execution::CompensationFacade.new(
        correlation_id: state.correlation_id,
        current_state: state.current_state,
        context: context,
        id_prefix: "staged:comp:#{state.id}:#{name}"
      )

      begin
        SagaForge.guarding_execution { block.call(facade) }
      rescue => error
        return record_comp_error(name, error)
      end

      inserted = nil
      state.with_lock do
        committed = facade.context
        meta = (committed["__saga_forge"] || {}).dup
        meta["compensated"] = (meta["compensated"] || []) + [name.to_s]
        committed["__saga_forge"] = meta
        state.update!(context: committed, version: state.version + 1)
        # Staged event_ids are namespaced by state id + compensation name, and
        # a completed name is never re-run (the compensated-append commits
        # atomically with these inserts) — RecordNotUnique here is an
        # invariant violation and should raise loudly, so no rescue.
        inserted = facade.staged_publishes.map { |attrs| Event.create!(attrs) }
      end
      Array(inserted).each { |row| ExecutionJob.perform_later(row.id) }
      :continue
    end

    def record_comp_error(name, error)
      backoff = nil
      state.with_lock do
        # deep_dup — NOT `state.context` mutated in place. With no other
        # attribute changing on the exhaustion path, an in-place mutation of
        # the same Hash object AR already holds as the "before" snapshot
        # would make old_value.equal-content?(new_value) true (same object,
        # so `!=` sees no diff) and the whole write would silently no-op.
        # A fresh dup is a different object with different content, so the
        # change is always detected.
        context = state.context.deep_dup
        meta = (context["__saga_forge"] || {}).dup
        attempts = (meta["comp_attempts"] || {}).dup
        attempts[name.to_s] = attempts.fetch(name.to_s, 0) + 1
        meta["comp_attempts"] = attempts

        backoff = RetryPolicy.compensation_default.retry_backoff(error, attempts: attempts[name.to_s])
        unless backoff
          meta["comp_error"] = {
            "name" => name.to_s,
            "class" => error.class.name,
            "message" => SagaForge.safe_error_message(error.message, COMP_ERROR_MESSAGE_LIMIT)
          }
          Rails.logger.error { "[saga_forge] compensation #{name} exhausted for #{state.saga_class}##{state.correlation_id}: #{error.class}" }
        end

        context["__saga_forge"] = meta
        state.update!(context: context)
      end
      backoff ? [:retry, backoff] : [:done]
    end

    def finalize!
      state.with_lock do
        target = state.context.dig("__saga_forge", "target") || "compensated"
        state.update!(current_state: target, version: state.version + 1)
      end
      [:done]
    end
  end
end

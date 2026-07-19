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

        entry_version = state.version
        begin
          outcome = run_one(definition, name, entry_version)
        rescue ConcurrencyConflict
          # Lost the race to another CompensationJob for this same instance
          # (defense-in-depth — limits_concurrency should make this rare in
          # practice). Nothing was written on this path: the raise happens
          # inside run_one's with_lock, before any update!, so no
          # comp_attempts/comp_error bookkeeping to unwind. Re-loop: reload
          # picks up the winner's committed progress, next_owed re-derives
          # against it, and we snapshot fresh before trying again.
          next
        end
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

    def run_one(definition, name, entry_version)
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
        # facade.context was built from a pre-lock read (above); with_lock's
        # reload just refreshed state to whatever's actually committed. If
        # another CompensationJob for this same instance landed a compensation
        # in between, state.version has moved past entry_version — writing
        # `committed` (the whole context, built from our stale snapshot) now
        # would silently clobber that instance's progress (lost context keys,
        # a "completed" name no longer in `compensated`, so it'd look owed
        # again). Mirrors Execution::Runner#commit!'s optimistic-concurrency
        # check; on conflict we raise and let #call re-loop against fresh
        # state rather than trying to merge two contexts here.
        raise ConcurrencyConflict, "compensation version moved" if state.version != entry_version

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
        # deep_dup — not because in-place mutation would fool Rails' dirty
        # tracking (JSON/JSONB attributes re-deserialize the stored raw value
        # and diff by content on every check, so an in-place mutation IS
        # detected correctly; that concern doesn't hold up). This is snapshot
        # isolation, the same pre-lock-read discipline used everywhere else
        # context is worked on (Execution::Runner#execute!, this class's own
        # #run_one): treat state.context as a value read at a point in time,
        # and hand back an independent copy rather than mutating the live
        # attribute object in place.
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

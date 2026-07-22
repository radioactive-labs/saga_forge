module SagaForge
  # A stale timer firing late is discarded by the version fence — the same
  # principle that powers stalling. The clock resets on each handled event
  # because every commit bumps version and re-arms (§A.1).
  class TimeoutJob < ActiveJob::Base
    include Execution::PostCommit

    queue_as { SagaForge.config.job_queue }

    # See ExecutionJob::CONCURRENCY_KEY for why this is a constant. `*` soaks
    # up the job's other two arguments (event_name, armed_version) — only the
    # state matters for the lock key.
    CONCURRENCY_KEY = ->(state_id, *) {
      state = State.find_by(id: state_id)
      state ? "SagaLock:#{state.saga_class}:#{state.correlation_id}" : "SagaLock:none"
    }

    if defined?(SolidQueue)
      limits_concurrency key: CONCURRENCY_KEY
    end

    def perform(state_id, event_name, armed_version)
      state = State.find_by(id: state_id)
      return unless state
      return if state.version != armed_version # stale timer — cheap pre-check

      definition = state.saga_definition
      handler = definition.handler_for(event_name)
      return unless handler&.timeout

      # Definition#validate_timeouts! guarantees on_timeout is present
      # (:fail! or a declared state) whenever timeout: is declared — no nil
      # case to handle here.
      case handler.on_timeout.to_sym
      when :fail!
        fail_saga!(state, armed_version)
      else
        branch!(state, definition, handler.on_timeout, armed_version)
      end
    end

    private

    def fail_saga!(state, armed_version)
      transitioned = false
      state.with_lock do
        break if state.version != armed_version # re-check under the lock

        # HWIA aliasing pitfall (see CompensationRunner#record_comp_error):
        # `context["__saga_forge"] ||= {}` would evaluate to an orphan hash
        # never written back to context. Merge and reassign in one shot.
        context = state.context.deep_dup
        meta = (context["__saga_forge"] || {}).merge(
          "failure_reason" => "timeout", "target" => "compensated"
        )
        context["__saga_forge"] = meta
        state.update!(current_state: State::COMPENSATING.to_s,
          version: state.version + 1, context: context, last_active_at: Time.current)
        transitioned = true
      end
      CompensationJob.perform_later(state.id) if transitioned
    end

    # declared? is re-checked at fire time as a belt-and-braces invariant:
    # boot validation (Definition#validate_timeouts!) can't see a state that
    # gets removed in a later deploy while an old timer is still armed — that
    # must scream, not silently discard.
    def branch!(state, definition, target, armed_version)
      target = target.to_s
      unless definition.declared?(target)
        raise UnknownStateError, "on_timeout: #{target} is not a declared state"
      end

      begin
        guard_forward_only!(definition, state.saga_class, state.correlation_id, state.current_state, target)
      rescue ForwardOnlyError => e
        Rails.logger.error { "[saga_forge] timeout branch rejected: #{e.message}" }
        return
      end

      transitioned = false
      state.with_lock do
        break if state.version != armed_version
        now = Time.current
        finalized = definition.terminal?(target.to_sym) ? now : nil
        state.update!(current_state: target, version: state.version + 1,
          last_active_at: now, finalized_at: finalized)
        transitioned = true
      end
      return unless transitioned

      redeliver_parked(definition, state)
      arm_timeouts(definition, state)
    end
  end
end

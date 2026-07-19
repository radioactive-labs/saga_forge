module SagaForge
  # A stale timer firing late is discarded by the version fence — the same
  # principle that powers stalling. The clock resets on each handled event
  # because every commit bumps version and re-arms (§A.1).
  class TimeoutJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(state_id, event_name, armed_version)
      state = State.find_by(id: state_id)
      return unless state
      return if state.version != armed_version # stale timer — cheap pre-check

      definition = state.saga_definition
      handler = definition.handler_for(event_name)
      return unless handler&.timeout

      case handler.on_timeout&.to_sym
      when :fail!
        fail_saga!(state, armed_version)
      when nil
        Rails.logger.warn { "[saga_forge] timeout fired for #{state.saga_class}##{state.correlation_id} but handler declares no on_timeout — ignoring" }
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
          version: state.version + 1, context: context)
        transitioned = true
      end
      CompensationJob.perform_later(state.id) if transitioned
    end

    def branch!(state, definition, target, armed_version)
      target = target.to_s
      unless definition.declared?(target)
        raise UnknownStateError, "on_timeout: #{target} is not a declared state"
      end

      transitioned = false
      state.with_lock do
        break if state.version != armed_version
        state.update!(current_state: target, version: state.version + 1)
        transitioned = true
      end
      return unless transitioned

      redeliver_parked_for(state, definition)
      rearm(state, definition)
    end

    def redeliver_parked_for(state, definition)
      names = definition.events_for_state(state.current_state).map(&:to_s)
      return if names.empty?
      Event.stalled.for_instance(state.saga_class, state.correlation_id)
        .where(event_name: names).ledger_order.each do |parked|
        parked.update!(status: :pending, stall_count: 0)
        ExecutionJob.perform_later(parked.id)
      end
    end

    def rearm(state, definition)
      definition.events_for_state(state.current_state.to_sym).each do |event_name|
        handler = definition.handler_for(event_name)
        next unless handler.timeout
        TimeoutJob.set(wait: handler.timeout).perform_later(state.id, event_name.to_s, state.version)
      end
    end
  end
end

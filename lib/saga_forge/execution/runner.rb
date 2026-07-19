module SagaForge
  module Execution
    # Processes one pending ledger row through the §A.4 pipeline.
    # Returns [:done] | [:respin] | [:retry, seconds].
    class Runner
      attr_reader :event

      def initialize(event)
        @event = event
      end

      def call
        return [:done] unless event.pending?
        return [:done] if halted?

        saga_class = event.saga_class.constantize
        definition = saga_class.definition
        state_row = State.find_by(saga_class: event.saga_class, correlation_id: event.correlation_id)
        current = state_row&.current_state&.to_sym || Definition::START

        return discard_terminal!(current) if definition.terminal?(current)

        expected = definition.state_for_event(event.event_name)
        return stall! if expected != current

        execute!(definition, state_row, current)
      end

      private

      # Poison-pill halt (§A.3): derived from the ledger at job entry.
      def halted?
        Event.failed.for_instance(event.saga_class, event.correlation_id).exists?
      end

      # Atomic increment (not read-modify-write): concurrent deliveries outside
      # Solid Queue's serialization must not lose updates (§A.3 — correctness
      # never depends on the concurrency-limit nicety).
      def stall!
        Event.where(id: event.id).update_all("stall_count = stall_count + 1")
        count = event.reload.stall_count
        if count >= SagaForge.config.stall_budget
          event.update!(status: :stalled)
          [:done]
        else
          [:respin]
        end
      end

      def discard_terminal!(current)
        event.update!(status: :processed, error: {"discarded" => "terminal state #{current}"})
        Rails.logger.info { "[saga_forge] discarded #{event.event_name} for terminal #{event.saga_class}##{event.correlation_id}" }
        [:done]
      end

      def execute!(definition, state_row, current)
        handler = definition.handler_for(event.event_name)
        entry_version = state_row&.version || 0
        context = (state_row&.context || {}).deep_dup.with_indifferent_access

        facade = Facade.new(
          definition: definition,
          correlation_id: event.correlation_id,
          current_state: current,
          context: context,
          source_event_id: event.id
        )

        begin
          catch(:saga_forge_fail) do
            SagaForge.guarding_execution do
              handler.block.call(facade, event.payload.with_indifferent_access)
            end
          end
        rescue => error
          return handle_error(error, definition, handler)
        end

        state_row = commit!(definition, state_row, current, entry_version, facade)
        after_commit_effects(definition, state_row, facade)
        [:done]
      rescue ConcurrencyConflict
        [:retry, SagaForge.config.stall_wait]
      end

      # Routes BLOCK errors through the resolved retry policy (§A.5):
      # handler override -> class default -> RetryPolicy.step_default. Retryable
      # -> event stays pending with bumped attempts/budgets, [:retry, backoff].
      # Exhausted or unmatched -> event failed with captured error, [:done];
      # nothing escapes to ActiveJob's dead-letter path.
      #
      # Structural warning: this hook is for BLOCK errors only. ConcurrencyConflict
      # (raised only from commit!, and itself a SagaForge::Error subclass) is
      # deliberately caught by the method-level `rescue ConcurrencyConflict`
      # on execute! — which sits AFTER this hook in the call chain, catching
      # only what commit! raises, never what the block raises. Do not
      # restructure this so ConcurrencyConflict could reach a generic
      # `rescue => error` here — that would burn retry-policy budget on a
      # version race, which isn't a block failure. Likewise, the fail! verb
      # unwinds via `throw :saga_forge_fail`, not a raised exception, so it
      # never reaches handle_error and must never be routed through
      # retry-policy logic either.
      def handle_error(error, definition, handler)
        policy = definition.retry_policy_for(handler)
        attempts = event.attempts + 1
        budgets = (event.retry_budgets || {}).dup
        updates = {attempts: attempts}

        backoff = policy.retry_backoff(error, attempts: attempts) do |budget_key|
          budgets[budget_key] = budgets.fetch(budget_key, 0) + 1
          updates[:retry_budgets] = budgets
          budgets[budget_key]
        end

        if backoff
          event.update!(**updates)
          [:retry, backoff]
        else
          event.update!(**updates, status: :failed, error: {
            "class" => error.class.name,
            "message" => error.message.to_s.truncate(10_000),
            "backtrace" => Array(error.backtrace).first(50)
          })
          Rails.logger.error { "[saga_forge] #{event.saga_class}##{event.correlation_id} #{event.event_name} failed: #{error.class}: #{error.message}" }
          [:done]
        end
      end

      def commit!(definition, state_row, current, entry_version, facade)
        failing = facade.outcome.is_a?(Array) && facade.outcome.first == :fail
        next_state = resolve_next_state(definition, current, facade.outcome)
        @inserted_rows = []

        State.transaction do
          if state_row.nil?
            begin
              state_row = State.create!(
                saga_class: event.saga_class, correlation_id: event.correlation_id,
                current_state: next_state, version: entry_version, context: {}
              )
            rescue ActiveRecord::RecordNotUnique
              raise ConcurrencyConflict, "duplicate start for #{event.saga_class}##{event.correlation_id}"
            end
          end
          state_row.lock!
          raise ConcurrencyConflict, "version moved" if state_row.version != entry_version

          context = facade.context
          if failing
            # NOTE: `context["__saga_forge"] ||= {}` would look right but isn't:
            # HashWithIndifferentAccess#[]= stores its own converted copy
            # internally, while the assignment *expression* always evaluates
            # to the literal right-hand object Ruby wrote (a core `[]=`
            # semantic) — so a `meta = (context[k] ||= {})` alias points at
            # an orphan hash that never lands back in `context`. Merge and
            # reassign in one shot instead.
            meta = (context["__saga_forge"] || {}).merge(
              "failure_reason" => facade.outcome.last,
              "target" => "compensated"
            )
            context["__saga_forge"] = meta
          end

          state_row.update!(current_state: next_state, version: entry_version + 1, context: context)
          event.update!(status: :processed, saga_forge_state_id: state_row.id, error: nil)

          unless failing # fail! discards staged publishes (§A.1)
            # RecordNotUnique here is unreachable by design, not defensively
            # rescued: staged event_ids are namespaced by THIS run's own
            # source event id ("staged:#{event.id}:#{seq}"), and the
            # processed-skip at Runner#call's entry means a source event
            # that already committed can never re-run its block and re-stage
            # those same ids. A raise here is a loud invariant violation on
            # purpose — do not add a rescue.
            @inserted_rows = facade.staged_publishes.map { |attrs| Event.create!(attrs) }
          end
        end
        state_row
      end

      def resolve_next_state(definition, current, outcome)
        case outcome
        in nil then definition.successor_of(current).to_s
        in :stay then current.to_s
        in [:transition_to, target] then target.to_s
        in [:fail, _] then State::COMPENSATING.to_s
        end
      end

      def after_commit_effects(definition, state_row, facade)
        @inserted_rows.each { |row| ExecutionJob.perform_later(row.id) }

        if state_row.current_state == State::COMPENSATING.to_s
          CompensationJob.perform_later(state_row.id)
          return
        end

        redeliver_parked(definition, state_row)
        arm_timeouts(definition, state_row)
      end

      def redeliver_parked(definition, state_row)
        names = definition.events_for_state(state_row.current_state).map(&:to_s)
        return if names.empty?
        Event.stalled.for_instance(event.saga_class, event.correlation_id)
          .where(event_name: names).ledger_order.each do |parked|
          parked.update!(status: :pending, stall_count: 0)
          ExecutionJob.perform_later(parked.id)
        end
      end

      def arm_timeouts(definition, state_row)
        # Task 9.
      end
    end
  end
end

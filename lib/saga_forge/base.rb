module SagaForge
  # The saga DSL. Macros only record; Definition.compile (lazy, memoized)
  # builds and validates the machine. The file IS the state machine.
  class Base
    class << self
      attr_reader :correlator, :default_retry_policy

      def inherited(subclass)
        super
        Router.register(subclass)
      end

      def correlate_by(key = nil, &block)
        @correlator = block || ->(payload, _event = nil) { payload[key] }
      end

      def start_with(event, compensate: nil, timeout: nil, on_timeout: nil, retry_policy: nil, &block)
        declarations << {kind: :start, event: event.to_sym, compensate:, timeout:, on_timeout:, retry_policy:, block:}
      end

      def during(state, on:, compensate: nil, timeout: nil, on_timeout: nil, retry_policy: nil, &block)
        declarations << {kind: :during, state: state.to_sym, event: on.to_sym, compensate:, timeout:, on_timeout:, retry_policy:, block:}
      end

      def finish_with(state)
        declarations << {kind: :finish, state: state.to_sym}
      end

      def compensation(name, &block)
        declarations << {kind: :compensation, name: name.to_sym, block:}
      end

      def retry_policy(*policies, **kwargs)
        if policies.any? && kwargs.any?
          raise ArgumentError, "pass either policy objects or kwargs, not both"
        end
        @default_retry_policy =
          if policies.any?
            (policies.size == 1 && kwargs.empty?) ? policies.first : CompositeRetryPolicy.new(policies)
          else
            RetryPolicy.new(**kwargs)
          end
      end

      def declarations = @declarations ||= []

      def definition = @definition ||= Definition.compile(self)

      # Introspection & recovery (class-level; instance ops land in Task 11).
      def find_by_correlation(correlation_id) = State.for_saga(self).find_by(correlation_id: correlation_id.to_s)

      def in_state(state) = State.for_saga(self).in_state(state)

      def stalled = State.for_saga(self).stalled

      def suspended = State.for_saga(self).suspended

      def to_mermaid = definition.to_mermaid
    end
  end
end

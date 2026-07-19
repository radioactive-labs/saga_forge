module SagaForge
  # Boot-time event → saga-class registry + the shared row builder used by
  # both publish paths. Registration happens in Base.inherited; reset on
  # code reload (railtie to_prepare).
  class Router
    @classes = []

    class << self
      def register(klass)
        @classes << klass unless @classes.include?(klass)
      end

      def reset! = @classes = []

      def saga_classes = @classes

      def recipients_for(event_name)
        event = event_name.to_sym
        @classes.select { |k| handler_for(k, event) }
      end

      # One fully-built Event attribute hash per recipient class. Raises
      # MissingCorrelationError before anything is inserted — atomic publish.
      def resolve(event_name, payload)
        payload = payload.with_indifferent_access
        recipients_for(event_name).map do |klass|
          {
            saga_class: klass.name,
            correlation_id: klass.definition.correlate(payload, event_name.to_sym),
            event_name: event_name.to_s,
            payload: payload,
            status: :pending
          }
        end
      end

      private

      # A class whose Definition never compiled (e.g. a mid-declaration DSL
      # error) is simply not a recipient of anything — it's not this
      # publish's problem. Only DSL/boot-time errors are swallowed here;
      # Definition#correlate raising MissingCorrelationError for a class that
      # DOES handle this event (i.e. a real recipient whose payload lacks the
      # correlation key) happens later, in #resolve, and still aborts the
      # whole publish as required.
      #
      # This should be unreachable in practice — the railtie force-compiles
      # every registered class at boot/reload, so a broken saga crashes
      # loudly long before any publish reaches here (§A.8). This rescue is
      # defense-in-depth for non-railtie usage (the gem used standalone,
      # without Rails booting it), so we still log loudly rather than skip
      # in silence.
      def handler_for(klass, event)
        klass.definition.handler_for(event)
      rescue Error => e
        if defined?(Rails)
          Rails.logger.error { "[saga_forge] #{klass.name} failed to compile its definition — skipped as recipient: #{e.class}: #{e.message}" }
        end
        nil
      end
    end
  end
end

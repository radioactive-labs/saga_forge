module SagaForge
  # Boot-time event → saga-class registry + the shared row builder used by
  # both publish paths. Registration happens in Base.inherited; reset on
  # code reload (railtie to_prepare).
  #
  # No internal locking around @classes: register/reset!/compile_all! are
  # only ever called from the main autoloader (Base.inherited during load,
  # railtie to_prepare during reload), and Rails' reloader interlock already
  # serializes those against request threads.
  class Router
    @classes = []

    class << self
      def register(klass)
        @classes << klass unless @classes.include?(klass)
      end

      def reset! = @classes = []

      def saga_classes = @classes

      # Forces every registered class to compile its Definition right now,
      # so a broken saga (bad DSL, missing correlate_by, etc.) raises here —
      # loudly, at boot/reload (§A.8) — instead of being silently skipped as
      # a recipient the first time something happens to publish its event.
      def compile_all! = saga_classes.each(&:definition)

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
      # Belt-and-braces: the railtie force-compiles every registered class at
      # boot/reload (§A.8), so a broken saga crashes loudly long before any
      # publish reaches here — but if one somehow does, log loudly rather than
      # skip in silence.
      def handler_for(klass, event)
        klass.definition.handler_for(event)
      rescue Error => e
        Rails.logger.error { "[saga_forge] #{klass.name} failed to compile its definition — skipped as recipient: #{e.class}: #{e.message}" }
        nil
      end
    end
  end
end

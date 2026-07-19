# frozen_string_literal: true

require "zeitwerk"
require "active_record"
require "active_job"
require "digest"

module SagaForge
  Loader = Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/generators")
    loader.ignore("#{__dir__}/saga_forge/railtie.rb")
    loader.setup
  end

  class Error < StandardError; end

  # Boot-time definition errors
  class AmbiguousEventError < Error; end
  class UnknownCompensationError < Error; end
  class MissingCorrelationError < Error; end
  class NoTerminalStateError < Error; end
  class DefinitionError < Error; end

  # Runtime errors
  class UnknownStateError < Error; end
  class UnstagedPublishError < Error; end
  class ConcurrencyConflict < Error; end # internal: version race / duplicate create

  class << self
    def config = @config ||= Configuration.new

    def configure = yield(config)

    def reset_configuration! = @config = Configuration.new

    # External publish entry point. Raises UnstagedPublishError inside
    # saga execution — use saga.publish there. (Publisher lands in Task 4.)
    def publish(event_name, event_id: nil, **payload)
      Publisher.publish(event_name, event_id: event_id, payload: payload)
    end

    # PK type for engine tables: explicit config → host generator config → Rails default.
    def primary_key_type
      config.primary_key_type ||
        (defined?(Rails.application) && Rails.application &&
          Rails.application.config.generators.options.dig(:active_record, :primary_key_type)) ||
        :primary_key
    end

    # --- execution guard ---

    def within_saga_execution?
      !!ActiveSupport::IsolatedExecutionState[:saga_forge_execution]
    end

    # Wrapped around user block invocation ONLY (forward, compensation, timeout
    # blocks). Footgun-catcher, not a sandbox.
    def guarding_execution
      previous = ActiveSupport::IsolatedExecutionState[:saga_forge_execution]
      ActiveSupport::IsolatedExecutionState[:saga_forge_execution] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:saga_forge_execution] = previous
    end
  end
end

require "saga_forge/railtie" if defined?(Rails::Railtie)

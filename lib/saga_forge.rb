# frozen_string_literal: true

require "zeitwerk"
require "active_record"
require "active_job"

module SagaForge
  Loader = Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/generators")
    loader.ignore("#{__dir__}/saga_forge/railtie.rb")
    loader.setup
  end

  # dashboard/graph.rb defines three constants (Graph, Node, Edge) in one
  # file, which breaks Zeitwerk's one-file-one-constant autoload convention:
  # only the file's "primary" constant (Graph, matching the filename) gets an
  # autoload stub, so referencing Node or Edge first raises NameError. Require
  # it eagerly here so all three are real constants before anything uses them.
  require_relative "saga_forge/dashboard/graph"

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
  class ForwardOnlyError < Error; end # transition/advance re-enters a visited state

  class << self
    def config = @config ||= Configuration.new

    def configure = yield(config)

    def reset_configuration! = @config = Configuration.new

    # External publish entry point. Raises UnstagedPublishError inside
    # saga execution — use saga.publish there. (Publisher lands in Task 4.)
    def publish(event_name, **payload)
      Publisher.publish(event_name, payload: payload)
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

    # Encoding-safe truncation for persisting error text into JSON columns:
    # arbitrary bytes (binary paths, HTTP bodies) must never crash the
    # failure-recording path itself.
    def safe_error_message(msg, limit)
      msg.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}").truncate(limit)
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

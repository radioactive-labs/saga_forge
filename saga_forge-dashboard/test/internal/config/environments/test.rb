Rails.application.configure do
  config.active_job.queue_adapter = :test
  config.secret_key_base = "test-secret"
  config.action_dispatch.cookies_serializer = :json
  # Without this, ActionDispatch::ShowExceptions rescues a raised
  # AuthenticationNotConfigured into a 500 response instead of letting it
  # propagate to the test, which the fail-closed auth test asserts on directly.
  # Test-env only: production keeps Rails' default show_exceptions behavior.
  # This exists so fail-closed auth errors AND routing errors surface as raises
  # for assert_raises rather than being rendered into response pages. Consequence:
  # controller tests for "record not found" must use
  # assert_raises(ActiveRecord::RecordNotFound) rather than asserting a 404 status.
  config.action_dispatch.show_exceptions = :none
  # BaseController calls `protect_from_forgery` explicitly, so
  # default_protect_from_forgery (whether Rails auto-adds that call) is a
  # no-op here. This is the knob that actually disables verification for
  # Rack::Test requests (no CSRF token) in the test env only.
  config.action_controller.allow_forgery_protection = false
end

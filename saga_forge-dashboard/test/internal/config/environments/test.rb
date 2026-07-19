Rails.application.configure do
  config.active_job.queue_adapter = :test
  config.secret_key_base = "test-secret"
  config.action_dispatch.cookies_serializer = :json
  # BaseController calls `protect_from_forgery` explicitly, so
  # default_protect_from_forgery (whether Rails auto-adds that call) is a
  # no-op here. This is the knob that actually disables verification for
  # Rack::Test requests (no CSRF token) in the test env only.
  config.action_controller.allow_forgery_protection = false
end

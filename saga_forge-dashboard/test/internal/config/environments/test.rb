Rails.application.configure do
  config.active_job.queue_adapter = :test
  config.secret_key_base = "test-secret"
  config.action_dispatch.cookies_serializer = :json
  config.action_controller.default_protect_from_forgery = false
end

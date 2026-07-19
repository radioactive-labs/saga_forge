require "test_helper"

class AuthTest < SagaForge::Dashboard::TestCase
  test "unconfigured auth raises fail-closed" do
    SagaForge::Dashboard.reset_configuration! # clear the :none from setup
    assert_raises(SagaForge::Dashboard::AuthenticationNotConfigured) { get "/saga_forge" }
  end

  test "http_basic challenges then accepts" do
    SagaForge::Dashboard.reset_configuration!
    SagaForge::Dashboard.configure { |c| c.http_basic = {username: "a", password: "b"} }
    get "/saga_forge"
    assert_equal 401, last_response.status
    authorize "a", "b"
    get "/saga_forge"
    assert_equal 200, last_response.status
  end

  test "authenticate block runs in controller context" do
    SagaForge::Dashboard.reset_configuration!
    SagaForge::Dashboard.configure { |c| c.authenticate { |ctrl| ctrl.head(:forbidden) unless ctrl.request.get_header("HTTP_X_OK") } }
    get "/saga_forge"
    assert_equal 403, last_response.status
    get "/saga_forge", {}, {"HTTP_X_OK" => "1"}
    assert_equal 200, last_response.status
  end
end

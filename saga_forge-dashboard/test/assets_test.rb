require "test_helper"

class AssetsTest < SagaForge::Dashboard::TestCase
  test "serves css with immutable cache header, skips auth" do
    SagaForge::Dashboard.reset_configuration! # even with no auth, assets serve
    SagaForge::Dashboard.configure { |c| c.http_basic = {username: "a", password: "b"} }
    get "/saga_forge/assets/dashboard.css"
    assert_equal 200, last_response.status
    assert_match "text/css", last_response.headers["Content-Type"]
    assert_match "immutable", last_response.headers["Cache-Control"]
  end

  test "unlisted asset 404s at the route" do
    # The route's regex constraint doesn't match, so this is a routing error, not
    # a controller-level not_found. In production (show_exceptions default),
    # Rails' exceptions_app renders that as a plain 404. Here the test env sets
    # config.action_dispatch.show_exceptions = :none (required so the auth
    # fail-closed test above can assert_raises on AuthenticationNotConfigured
    # instead of it being rescued into a 500 page) which also means routing
    # errors propagate as a raised exception rather than a 404 response.
    assert_raises(ActionController::RoutingError) { get "/saga_forge/assets/secrets.rb" }
  end
end

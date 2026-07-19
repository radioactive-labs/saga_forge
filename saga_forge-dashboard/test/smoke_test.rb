require "test_helper"

class SmokeTest < SagaForge::Dashboard::TestCase
  test "mounted root responds 200" do
    get "/saga_forge"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Sagas"
  end

  test "config round-trips and asset_digest shape" do
    SagaForge::Dashboard.configure { |c| c.page_size = 10 }
    assert_equal 10, SagaForge::Dashboard.config.page_size
    SagaForge::Dashboard.reset_configuration!
    assert_equal 50, SagaForge::Dashboard.config.page_size
  end
end

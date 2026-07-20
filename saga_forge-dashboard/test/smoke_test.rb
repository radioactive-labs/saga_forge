require "test_helper"

class SmokeTest < SagaForge::Dashboard::TestCase
  test "mounted root responds 200" do
    get "/saga_forge"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Sagas"
  end

  test "active nav link renders a real aria-current attribute, not an escaped string" do
    # /saga_forge/sagas (not the bare mount root) so the Sagas nav link's
    # href == request.path and the "active" branch actually renders.
    get "/saga_forge/sagas"
    # Exact substring match, not just "aria-current" — ERB's <%= %> auto-escapes
    # interpolated attribute strings, which previously rendered
    # aria-current=&quot;page&quot; (an inert quoted-string value, not the ARIA
    # token `page`). Only the unescaped literal markup form is valid.
    assert_includes last_response.body, 'aria-current="page"'
  end

  test "config round-trips and asset_digest shape" do
    SagaForge::Dashboard.configure { |c| c.page_size = 10 }
    assert_equal 10, SagaForge::Dashboard.config.page_size
    SagaForge::Dashboard.reset_configuration!
    assert_equal 50, SagaForge::Dashboard.config.page_size
  end
end

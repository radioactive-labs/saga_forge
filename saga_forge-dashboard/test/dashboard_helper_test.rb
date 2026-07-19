require "test_helper"

class DashboardHelperTest < SagaForge::Dashboard::TestCase
  include SagaForge::Dashboard::DashboardHelper

  def cookies = {}

  test "bar width clamps" do
    assert_equal "sf-bar-100", bar_width_class(150)
    assert_equal "sf-bar-0", bar_width_class(-5)
  end

  test "status badge colors" do
    assert_match "sf-badge-red", status_badge("failed")
    assert_match "sf-badge-green", status_badge("processed")
  end

  test "format bytes" do
    assert_equal "1.0 KB", format_bytes(1024)
  end
end

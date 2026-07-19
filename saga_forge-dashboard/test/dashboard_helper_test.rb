require "test_helper"

class DashboardHelperTest < SagaForge::Dashboard::TestCase
  include SagaForge::Dashboard::DashboardHelper

  # Instance-variable backed so individual tests can flip the time-format
  # preference (set_absolute_time!) without a class-level override forcing
  # every other test into one mode.
  def cookies = @cookies ||= {}

  def set_absolute_time! = @cookies = {sf_time_format: "absolute"}

  test "bar width clamps" do
    assert_equal "sf-bar-100", bar_width_class(150)
    assert_equal "sf-bar-0", bar_width_class(-5)
  end

  test "status badge colors" do
    assert_match "sf-badge-red", status_badge("failed")
    assert_match "sf-badge-green", status_badge("processed")
  end

  test "state badge colors" do
    assert_match "sf-badge-indigo", state_badge("running")
    assert_match "sf-badge-green", state_badge("completed")
    assert_match "sf-badge-amber", state_badge("compensating")
  end

  test "format bytes" do
    assert_equal "1.0 KB", format_bytes(1024)
  end

  test "format bytes guards zero and negative" do
    assert_equal "0 B", format_bytes(0)
    assert_equal "0 B", format_bytes(-5)
  end

  test "poll interval falls back to config when cookie absent" do
    assert_equal SagaForge::Dashboard.config.polling_interval, poll_interval
  end

  test "time_tag renders relative by default, with the absolute form on hover" do
    out = time_tag(3.minutes.ago)
    assert_includes out, "ago"
    assert_includes out, "UTC" # the title attribute carries the other form
  end

  test "time_tag renders absolute when sf_time_format=absolute, with relative on hover" do
    set_absolute_time!
    out = time_tag(3.minutes.ago)
    assert_includes out, "UTC"
    assert_includes out, "ago" # the title attribute carries the other form
  end

  test "time_tag output differs between relative and absolute preference" do
    t = 3.minutes.ago
    relative_html = time_tag(t)
    set_absolute_time!
    absolute_html = time_tag(t)
    refute_equal relative_html, absolute_html
  end
end

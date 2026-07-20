require "test_helper"

class TimelinePresenterTest < SagaForge::Dashboard::TestCase
  test "merges events and compensation progress" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "compensated",
      context: {"__saga_forge" => {"compensated" => ["undo_a"], "comp_attempts" => {"undo_a" => 1}}})
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "c1",
      event_name: "demo_started", status: :processed, state: s, created_at: 2.minutes.ago)
    entries = SagaForge::Dashboard::TimelinePresenter.new(s).sorted
    kinds = entries.map(&:kind)
    assert_includes kinds, :event
    assert_includes kinds, :compensation
    comp = entries.find { |e| e.kind == :compensation }
    assert_equal "undo_a", comp.label
  end
end

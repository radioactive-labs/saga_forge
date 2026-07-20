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

  test "compensation entries preserve recorded order across many steps" do
    # All compensation entries share the same synthetic `at` (state.updated_at),
    # so without an index tiebreak Array#sort_by's lack of stability guarantee
    # can reorder them. 10 elements reliably exercises MRI's non-insertion-sort
    # path (empirically: instability shows up at n >= 8 on this Ruby).
    names = (1..10).map { |i| "undo_#{i}" }
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "compensated",
      context: {"__saga_forge" => {"compensated" => names}})
    comp_labels = SagaForge::Dashboard::TimelinePresenter.new(s).sorted
      .select { |e| e.kind == :compensation }.map(&:label)
    assert_equal names, comp_labels
  end

  test "memoizes entries and sorted across repeated calls" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c3", current_state: "x")
    SagaForge::Event.create!(event_id: "e3", saga_class: "DemoSaga", correlation_id: "c3",
      event_name: "demo_started", status: :processed, state: s)
    presenter = SagaForge::Dashboard::TimelinePresenter.new(s)
    assert_same presenter.entries, presenter.entries
    assert_same presenter.sorted, presenter.sorted
  end

  test "caps the timeline to the most recent MAX_ENTRIES events" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c4", current_state: "x")
    total = SagaForge::Dashboard::TimelinePresenter::MAX_ENTRIES + 5
    now = Time.current
    rows = (1..total).map do |i|
      {event_id: "e#{i}", saga_class: "DemoSaga", correlation_id: "c4", saga_forge_state_id: s.id,
       event_name: "step_#{i}", status: 1, payload: {}, retry_budgets: {},
       created_at: now + i.seconds, updated_at: now + i.seconds}
    end
    SagaForge::Event.insert_all(rows)

    presenter = SagaForge::Dashboard::TimelinePresenter.new(s)
    kept = presenter.sorted.select { |e| e.kind == :event }

    assert presenter.truncated?
    assert_equal total, presenter.total_event_count
    assert_equal SagaForge::Dashboard::TimelinePresenter::MAX_ENTRIES, kept.size
    assert_equal "step_#{total}", kept.last.label
    assert_equal "step_#{total - SagaForge::Dashboard::TimelinePresenter::MAX_ENTRIES + 1}", kept.first.label
  end
end

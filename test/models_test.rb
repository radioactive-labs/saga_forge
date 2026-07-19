require "test_helper"

class ModelsTest < SagaForge::TestCase
  def build_state(corr: "1", state: "waiting")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: corr, current_state: state)
  end

  test "event enum and dedup index" do
    s = build_state
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "went", payload: {a: 1}, state: s)
    assert_raises(ActiveRecord::RecordNotUnique) do
      SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "1",
        event_name: "went", payload: {a: 1})
    end
    SagaForge::Event.create!(event_id: "e1", saga_class: "OtherSaga", correlation_id: "1",
      event_name: "went", payload: {a: 1})
  end

  test "derived stalled and suspended scopes" do
    healthy = build_state(corr: "1")
    stalled = build_state(corr: "2")
    suspended = build_state(corr: "3")
    SagaForge::Event.create!(event_id: "s1", saga_class: "DemoSaga", correlation_id: "2",
      event_name: "early", status: :stalled, state: stalled)
    SagaForge::Event.create!(event_id: "f1", saga_class: "DemoSaga", correlation_id: "3",
      event_name: "boom", status: :failed, state: suspended)

    assert_equal [stalled.id], SagaForge::State.stalled.ids
    assert_equal [suspended.id], SagaForge::State.suspended.ids
    refute_includes SagaForge::State.stalled.ids, healthy.id
  end

  test "history is ledger ordered" do
    s = build_state
    e1 = SagaForge::Event.create!(event_id: "a", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "one", state: s, created_at: 2.minutes.ago)
    e2 = SagaForge::Event.create!(event_id: "b", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "two", state: s, created_at: 1.minute.ago)
    assert_equal [e1.id, e2.id], s.history.ids
  end

  test "compensating scope" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "compensating")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "awaiting")
    assert_equal ["c1"], SagaForge::State.compensating.pluck(:correlation_id)
  end

  test "json columns default to empty hashes on every adapter" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "d1", current_state: "waiting")
    assert_equal({}, s.reload.context)
    e = SagaForge::Event.create!(event_id: "def1", saga_class: "DemoSaga", correlation_id: "d1", event_name: "went")
    assert_equal({}, e.reload.payload)
    assert_equal({}, e.reload.retry_budgets)
    assert_nil e.reload.error
  end
end

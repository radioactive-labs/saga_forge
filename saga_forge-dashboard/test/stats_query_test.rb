require "test_helper"

class StatsQueryTest < SagaForge::Dashboard::TestCase
  test "counts by derived scope" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(saga_class: "DemoSaga", correlation_id: "c1", event_name: "x", status: :failed, state: s)
    counts = SagaForge::Dashboard::StatsQuery.new(saga_class: DemoSaga).counts
    assert_equal 1, counts[:all]
    assert_equal 1, counts[:suspended]
    assert_equal 0, counts[:stalled]
    assert_equal 0, counts[:finalized]
  end

  test "finalized counts states with a persisted finalized_at" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_complete",
      finalized_at: Time.current)
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "demo_waiting")
    counts = SagaForge::Dashboard::StatsQuery.new(saga_class: DemoSaga).counts
    assert_equal 2, counts[:all]
    assert_equal 1, counts[:finalized]
  end

  test "active is its own capped scope, not all-minus-finalized" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_complete",
      finalized_at: Time.current)
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "demo_waiting")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c3", current_state: "demo_waiting")
    counts = SagaForge::Dashboard::StatsQuery.new(saga_class: DemoSaga).counts
    assert_equal 3, counts[:all]
    assert_equal 1, counts[:finalized]
    assert_equal 2, counts[:active]
  end
end

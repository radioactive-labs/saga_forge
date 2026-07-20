require "test_helper"

class StatsQueryTest < SagaForge::Dashboard::TestCase
  test "counts by derived scope" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "c1", event_name: "x", status: :failed, state: s)
    counts = SagaForge::Dashboard::StatsQuery.new(saga_class: DemoSaga).counts
    assert_equal 1, counts[:all]
    assert_equal 1, counts[:suspended]
    assert_equal 0, counts[:stalled]
  end
end

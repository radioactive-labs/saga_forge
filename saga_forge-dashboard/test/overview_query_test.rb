require "test_helper"

class OverviewQueryTest < SagaForge::Dashboard::TestCase
  test "rows group by class and state; totals derive from core scopes" do
    a = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "a", current_state: "demo_waiting")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "b", current_state: "compensating")
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "a",
      event_name: "x", status: :stalled, state: a)

    q = SagaForge::Dashboard::OverviewQuery.new
    assert_equal 1, q.rows["DemoSaga"]["demo_waiting"]
    assert_equal 1, q.rows["DemoSaga"]["compensating"]

    totals = q.totals
    assert_equal 2, totals[:all]
    assert_equal 1, totals[:stalled]
    assert_equal 0, totals[:suspended]
    assert_equal 1, totals[:compensating]
  end

  test "rows is empty when there are no saga instances" do
    assert_equal({}, SagaForge::Dashboard::OverviewQuery.new.rows)
  end
end

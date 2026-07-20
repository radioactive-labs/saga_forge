require "test_helper"

class SagasQueryTest < SagaForge::Dashboard::TestCase
  def mk(corr, state: "demo_waiting") = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: corr, current_state: state)

  test "keyset paginates by pk desc without count" do
    5.times { |i| mk("c#{i}") }
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, per: 2)
    assert_equal 2, q.records.size
    assert q.has_next?
    q2 = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, per: 2, before: q.next_cursor)
    assert_equal 2, q2.records.size
    refute_equal q.records.map(&:id), q2.records.map(&:id)
  end

  test "stalled filter composes the derived scope" do
    s = mk("s1")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "s1",
      event_name: "x", status: :stalled, state: s)
    mk("s2")
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, filter: "stalled")
    assert_equal ["s1"], q.records.map(&:correlation_id)
  end

  test "correlation prefix search escapes like wildcards" do
    mk("abc")
    mk("axx")
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, correlation: "ab")
    assert_equal ["abc"], q.records.map(&:correlation_id)
  end
end

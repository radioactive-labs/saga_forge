require "test_helper"

class ContextPresenterTest < SagaForge::Dashboard::TestCase
  test "separates user keys from engine meta" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "x",
      context: {"total" => 5, "__saga_forge" => {"target" => "compensated"}})
    p = SagaForge::Dashboard::ContextPresenter.new(s)
    assert_equal ["total"], p.user_nodes.map(&:key)
    assert_equal "compensated", p.saga_meta["target"]
    assert_equal "number", p.user_nodes.first.type
  end
end

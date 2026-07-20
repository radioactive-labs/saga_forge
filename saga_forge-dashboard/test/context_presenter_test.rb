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

  test "memoizes user_nodes across repeated calls" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "x",
      context: {"total" => 1})
    p = SagaForge::Dashboard::ContextPresenter.new(s)
    assert_same p.user_nodes, p.user_nodes
  end

  test "does not fully serialize a large collection value just to preview it" do
    big_array = (1..51).to_a
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c3", current_state: "x",
      context: {"batch" => big_array})
    node = SagaForge::Dashboard::ContextPresenter.new(s).user_nodes.first
    assert_equal "array", node.type
    assert_nil node.bytes
    assert_includes node.preview, "51 entries"
    assert_includes node.preview, "too large to preview"
  end

  test "still previews a small collection in full" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c4", current_state: "x",
      context: {"items" => [1, 2, 3]})
    node = SagaForge::Dashboard::ContextPresenter.new(s).user_nodes.first
    assert_equal "array", node.type
    assert_equal [1, 2, 3].to_json.bytesize, node.bytes
    assert_equal [1, 2, 3].to_json, node.preview
  end
end

require "test_helper"

class ActionsTest < SagaForge::Dashboard::TestCase
  test "resume flips failed event and redirects" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "c1", event_name: "demo_done", status: :failed, state: s)
    post "/saga_forge/sagas/#{s.id}/resume"
    assert_equal 302, last_response.status
    assert SagaForge::Event.where(event_id: "e").first.pending?
  end

  test "no-op flashes nothing to do" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "demo_waiting")
    post "/saga_forge/sagas/#{s.id}/retry_stalled"
    follow_redirect!
    assert_includes last_response.body, "Nothing to do"
  end

  test "bulk enqueues job" do
    assert_enqueued_with(job: SagaForge::Dashboard::BulkRecoveryJob) do
      post "/saga_forge/bulk/DemoSaga/resume"
    end
  end
end

require "test_helper"

class BulkRecoveryJobTest < SagaForge::Dashboard::TestCase
  # `only:` keeps perform_enqueued_jobs from recursively draining the
  # ExecutionJobs that resume!/retry_stalled! enqueue for the now-pending
  # events — Rails 7's test adapter drains nested jobs by default, which
  # would carry these all the way to :processed and defeat the assertion
  # that the job itself un-parked them.
  test "resumes every failed instance of the class" do
    2.times do |i|
      s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "b#{i}", current_state: "demo_waiting")
      SagaForge::Event.create!(event_id: "e#{i}", saga_class: "DemoSaga", correlation_id: "b#{i}", event_name: "demo_done", status: :failed, state: s)
    end
    perform_enqueued_jobs(only: SagaForge::Dashboard::BulkRecoveryJob) do
      SagaForge::Dashboard::BulkRecoveryJob.perform_later("DemoSaga", "resume")
    end
    assert_equal 2, SagaForge::Event.pending.count
  end

  test "retries every stalled instance of the class" do
    2.times do |i|
      s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "s#{i}", current_state: "demo_waiting")
      SagaForge::Event.create!(event_id: "st#{i}", saga_class: "DemoSaga", correlation_id: "s#{i}", event_name: "demo_done", status: :stalled, state: s)
    end
    perform_enqueued_jobs(only: SagaForge::Dashboard::BulkRecoveryJob) do
      SagaForge::Dashboard::BulkRecoveryJob.perform_later("DemoSaga", "retry_stalled")
    end
    assert_equal 2, SagaForge::Event.pending.count
  end
end

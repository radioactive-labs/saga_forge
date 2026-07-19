require "test_helper"

class TimeoutTest < SagaForge::TestCase
  test "commit arms one timeout job per timeout-declaring handler with post-commit version" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t1", id: 1)
    end
    s = TimeoutSaga.find_by_correlation(1)
    assert_equal "waiting", s.current_state
    armed = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::TimeoutJob" }
    assert_equal 1, armed.size
    assert_equal [s.id, "t_arrived", 1], armed.first["arguments"].first(3)
  end

  test "handled event resets the clock: stale timer discards silently" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t2", id: 2)
    end
    s = TimeoutSaga.find_by_correlation(2)
    SagaForge::TimeoutJob.perform_now(s.id, "t_arrived", 99) # wrong version
    assert_equal "waiting", s.reload.current_state
    assert_no_enqueued_jobs only: SagaForge::CompensationJob
  end

  test "missing state row discards silently" do
    assert_nothing_raised { SagaForge::TimeoutJob.perform_now(-1, "t_arrived", 1) }
  end

  test "on_timeout fail! compensates with timeout reason" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t3", id: 3)
    end
    s = TimeoutSaga.find_by_correlation(3)
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "t_arrived", s.version)
    end
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal "timeout", s.context.dig("__saga_forge", "failure_reason")
    assert_equal true, s.context["undone"]
  end

  test "on_timeout state branch transitions, re-delivers parked, processes to finish" do
    SagaForge.configure { |c| c.stall_budget = 1 }
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:tb_started, event_id: "t4", id: 4)
      SagaForge.publish(:tb_slow, event_id: "t5", id: 4) # early — parks
    end
    s = TimeoutBranchSaga.find_by_correlation(4)
    assert_equal "waiting_fast", s.current_state
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "tb_fast", s.version)
    end
    assert_equal "tb_finished", s.reload.current_state
  end

  test "undeclared on_timeout target raises loudly" do
    # BadTimeoutSaga inline: declared? check happens at fire time
    s = SagaForge::State.create!(saga_class: "TimeoutBranchSaga", correlation_id: "9",
      current_state: "waiting_fast", version: 1)
    job = SagaForge::TimeoutJob.new
    assert_raises(SagaForge::UnknownStateError) do
      job.send(:branch!, s, TimeoutBranchSaga.definition, :nonexistent_state, 1)
    end
  end

  test "stay re-arms: each handled event in a timeout state produces a fresh timer" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:st_started, event_id: "st1", id: 5)
    end
    clear_enqueued_jobs
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:st_tick, event_id: "st2", id: 5)
    end
    s = StayTimeoutSaga.find_by_correlation(5)
    armed = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::TimeoutJob" }
    assert_equal 1, armed.size
    assert_equal s.version, armed.first["arguments"].last # armed at fresh post-commit version
  end
end

require "test_helper"

class TimeoutTest < SagaForge::TestCase
  test "commit arms one timeout job per timeout-declaring handler with post-commit version" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, id: 1)
    end
    s = TimeoutSaga.find_by_correlation(1)
    assert_equal "waiting", s.current_state
    armed = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::TimeoutJob" }
    assert_equal 1, armed.size
    assert_equal [s.id, "t_arrived", 1], armed.first["arguments"].first(3)
  end

  test "handled event resets the clock: stale timer discards silently" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, id: 2)
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
      SagaForge.publish(:t_started, id: 3)
    end
    s = TimeoutSaga.find_by_correlation(3)
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "t_arrived", s.version)
    end
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal "timeout", s.context.dig("__saga_forge", "failure_reason")
    assert_equal true, s.context["undone"]
    assert_not_nil s.last_active_at
  end

  test "on_timeout state branch transitions, re-delivers parked, processes to finish" do
    SagaForge.configure { |c| c.stall_budget = 1 }
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:tb_started, id: 4)
      SagaForge.publish(:tb_slow, id: 4) # early — parks
    end
    s = TimeoutBranchSaga.find_by_correlation(4)
    assert_equal "waiting_fast", s.current_state
    pre_branch_active_at = s.last_active_at
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "tb_fast", s.version)
    end
    s.reload
    assert_equal "tb_finished", s.current_state
    assert_not_nil s.last_active_at
    assert s.last_active_at > pre_branch_active_at if pre_branch_active_at
  end

  test "a backward on_timeout branch is rejected: saga stays put, error logged, not silently applied" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:bt_started, id: 6)
      SagaForge.publish(:bt_go, id: 6)
    end
    s = BackwardTimeoutSaga.find_by_correlation(6)
    assert_equal "bt_b", s.current_state
    pre_version = s.version
    pre_active_at = s.last_active_at

    logged = nil
    original_error = Rails.logger.method(:error)
    Rails.logger.define_singleton_method(:error) { |&blk| logged = blk.call }
    begin
      SagaForge::TimeoutJob.perform_now(s.id, "bt_never", s.version)
    ensure
      Rails.logger.define_singleton_method(:error, original_error)
    end

    s.reload
    assert_equal "bt_b", s.current_state, "backward timeout branch must not silently apply"
    assert_equal pre_version, s.version
    assert_equal pre_active_at, s.last_active_at
    assert_match(/forward-only|re-enters/, logged.to_s)
  end

  test "on_timeout branch to a terminal state stamps finalized_at" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:tt_started, id: 7)
    end
    s = TerminalTimeoutSaga.find_by_correlation(7)
    assert_equal "tt_waiting", s.current_state
    assert_nil s.finalized_at
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "tt_never", s.version)
    end
    s.reload
    assert_equal "tt_done", s.current_state
    assert_not_nil s.finalized_at
    assert_not_nil s.last_active_at
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

  test "TimeoutJob.perform_now raises loudly for a stale-deploy on_timeout target" do
    # Definition#validate_timeouts! rejects an undeclared on_timeout target at
    # boot, so the only way this path fires in practice is a stale deploy: a
    # state that was declared (and validated) when the timer was armed gets
    # removed from the saga class in a later deploy, and the old timer fires
    # against the new code. Simulate that by handing perform_now's freshly
    # loaded state row a stand-in definition whose handler_for returns a
    # Handler with an on_timeout target nothing declares — the fire-time
    # `declared?` guard in `branch!` must still catch it and raise, not
    # silently discard. The real Definition object is deep-frozen (by
    # design — see Definition#deep_freeze!), so it can't be stubbed directly;
    # instead State#saga_definition is patched, scoped to this one
    # correlation_id, and restored in the ensure block.
    s = SagaForge::State.create!(saga_class: "TimeoutBranchSaga", correlation_id: "11",
      current_state: "waiting_fast", version: 1)
    stale_handler = SagaForge::Definition::Handler.new(
      state: :waiting_fast, event: :tb_fast, block: nil, compensate: nil,
      timeout: 5.minutes, on_timeout: :nonexistent_state, retry_policy: nil
    )
    fake_definition = Object.new
    fake_definition.define_singleton_method(:handler_for) { |_event| stale_handler }
    fake_definition.define_singleton_method(:declared?) { |_state| false }

    original_method = SagaForge::State.instance_method(:saga_definition)
    SagaForge::State.define_method(:saga_definition) do
      (correlation_id == "11") ? fake_definition : original_method.bind_call(self)
    end
    begin
      assert_raises(SagaForge::UnknownStateError) do
        SagaForge::TimeoutJob.perform_now(s.id, "tb_fast", 1)
      end
    ensure
      SagaForge::State.define_method(:saga_definition, original_method)
    end
  end

  test "on_timeout fires on :st_waiting when no st_tick ever arrives" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:st_started, id: 5)
    end
    s = StayTimeoutSaga.find_by_correlation(5)
    assert_equal "st_waiting", s.current_state
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "st_tick", s.version)
    end
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal "timeout", s.context.dig("__saga_forge", "failure_reason")
  end
end

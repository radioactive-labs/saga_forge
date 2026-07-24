require "test_helper"

class ConfigurationTest < SagaForge::TestCase
  test "defaults" do
    c = SagaForge::Configuration.new
    assert_equal 3.seconds, c.stall_wait
    assert_equal 3, c.stall_budget
    assert_equal 30.seconds, c.sweep_interval
    assert_equal 90.days, c.retention
    assert_equal :default, c.job_queue
    assert_equal :default, c.maintenance_queue
    assert_nil c.database
    assert_nil c.connects_to
    assert_nil c.primary_key_type
  end

  test "configure and reset" do
    SagaForge.configure { |c| c.stall_budget = 5 }
    assert_equal 5, SagaForge.config.stall_budget
    SagaForge.reset_configuration!
    assert_equal 3, SagaForge.config.stall_budget
  end

  test "maintenance_queue falls back to job_queue until set explicitly" do
    c = SagaForge::Configuration.new
    c.job_queue = :hot
    assert_equal :hot, c.maintenance_queue, "tracks job_queue when unset"
    c.maintenance_queue = :housekeeping
    assert_equal :housekeeping, c.maintenance_queue, "explicit value wins"
    assert_equal :hot, c.job_queue, "does not bleed back into job_queue"
  end

  test "maintenance jobs use the maintenance queue, hot-path jobs use job_queue" do
    SagaForge.configure do |c|
      c.job_queue = :hot
      c.maintenance_queue = :housekeeping
    end
    assert_equal "hot", SagaForge::ExecutionJob.new.queue_name
    assert_equal "hot", SagaForge::CompensationJob.new.queue_name
    assert_equal "hot", SagaForge::TimeoutJob.new.queue_name
    assert_equal "housekeeping", SagaForge::SweeperJob.new.queue_name
    assert_equal "housekeeping", SagaForge::RetentionJob.new.queue_name
  end

  test "migrations_database resolution order" do
    c = SagaForge::Configuration.new
    assert_nil c.migrations_database
    c.connects_to = {database: {writing: :saga, reading: :saga}}
    assert_equal :saga, c.migrations_database
    c.database = :billing
    assert_equal :billing, c.migrations_database
  end

  test "guard flag" do
    refute SagaForge.within_saga_execution?
    SagaForge.guarding_execution do
      assert SagaForge.within_saga_execution?
    end
    refute SagaForge.within_saga_execution?
  end
end

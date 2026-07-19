require "test_helper"

class ConfigurationTest < SagaForge::TestCase
  test "defaults" do
    c = SagaForge::Configuration.new
    assert_equal 3.seconds, c.stall_wait
    assert_equal 40, c.stall_budget
    assert_equal 30.seconds, c.sweep_interval
    assert_equal 90.days, c.retention
    assert_equal :sagas, c.job_queue
    assert_nil c.database
    assert_nil c.connects_to
    assert_nil c.primary_key_type
  end

  test "configure and reset" do
    SagaForge.configure { |c| c.stall_budget = 5 }
    assert_equal 5, SagaForge.config.stall_budget
    SagaForge.reset_configuration!
    assert_equal 40, SagaForge.config.stall_budget
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

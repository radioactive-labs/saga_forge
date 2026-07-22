require "test_helper"

class SchemaTest < SagaForge::TestCase
  test "tables and key indexes exist" do
    conn = SagaForge::ApplicationRecord.connection
    assert conn.table_exists?(:saga_forge_states)
    assert conn.table_exists?(:saga_forge_events)
    assert conn.index_exists?(:saga_forge_states, %i[saga_class correlation_id], unique: true)
    assert conn.index_exists?(:saga_forge_states, :current_state)
    assert conn.index_exists?(:saga_forge_states, :finalized_at)
    refute conn.index_exists?(:saga_forge_events, %i[event_id saga_class], unique: true)
    assert conn.index_exists?(:saga_forge_events, %i[saga_class correlation_id event_name], unique: true)
    assert conn.index_exists?(:saga_forge_events, %i[saga_class correlation_id status])
    assert conn.index_exists?(:saga_forge_events, %i[status created_at])

    state_columns = conn.columns(:saga_forge_states).map(&:name)
    assert_includes state_columns, "finalized_at"
    assert_includes state_columns, "last_active_at"

    event_columns = conn.columns(:saga_forge_events).map(&:name)
    refute_includes event_columns, "event_id"
    assert_includes event_columns, "last_processed_at"
  end
end

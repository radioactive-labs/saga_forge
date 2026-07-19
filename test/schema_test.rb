require "test_helper"

class SchemaTest < SagaForge::TestCase
  test "tables and key indexes exist" do
    conn = SagaForge::ApplicationRecord.connection
    assert conn.table_exists?(:saga_forge_states)
    assert conn.table_exists?(:saga_forge_events)
    assert conn.index_exists?(:saga_forge_states, %i[saga_class correlation_id], unique: true)
    assert conn.index_exists?(:saga_forge_states, :current_state)
    assert conn.index_exists?(:saga_forge_events, %i[event_id saga_class], unique: true)
    assert conn.index_exists?(:saga_forge_events, %i[saga_class correlation_id status])
    assert conn.index_exists?(:saga_forge_events, %i[status created_at])
  end
end

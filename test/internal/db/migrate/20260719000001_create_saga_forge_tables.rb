# This migration ships with saga_forge. Engine tables live wherever
# SagaForge::ApplicationRecord connects (primary DB by default).
class CreateSagaForgeTables < ActiveRecord::Migration[7.1]
  def change
    fk_type = SagaForge.primary_key_type
    fk_type = :bigint if fk_type == :primary_key

    create_table :saga_forge_states, id: SagaForge.primary_key_type do |t|
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      t.string :current_state, null: false
      t.integer :version, null: false, default: 0
      if t.respond_to?(:jsonb)
        t.jsonb :context, null: false, default: {}
      else
        t.json :context, null: false, default: {}
      end
      t.timestamps

      t.index %i[saga_class correlation_id], unique: true
      t.index %i[saga_class current_state]
    end

    create_table :saga_forge_events, id: SagaForge.primary_key_type do |t|
      t.string :event_id, null: false
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      # Lone-column index on saga_forge_state_id intentionally omitted:
      # the [saga_forge_state_id, created_at] index below covers left-prefix lookups.
      t.references :saga_forge_state, type: fk_type, foreign_key: {to_table: :saga_forge_states}, index: false
      t.string :event_name, null: false
      t.integer :status, null: false, default: 0
      t.integer :stall_count, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      if t.respond_to?(:jsonb)
        t.jsonb :payload, null: false, default: {}
        t.jsonb :retry_budgets, null: false, default: {}
        t.jsonb :error
      else
        t.json :payload, null: false, default: {}
        t.json :retry_budgets, null: false, default: {}
        t.json :error
      end
      t.timestamps

      t.index %i[event_id saga_class], unique: true
      t.index %i[saga_class correlation_id status]
      t.index %i[status created_at]
      t.index %i[saga_forge_state_id created_at]
    end
  end
end

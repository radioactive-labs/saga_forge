# frozen_string_literal: true

class InstallSagaForge < ActiveRecord::Migration[7.1]
  def change
    create_table :saga_forge_states, id: primary_key_type do |t|
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      t.string :current_state, null: false
      t.integer :version, null: false, default: 0

      if t.respond_to?(:jsonb)
        t.jsonb :context, null: false, default: {}
      else
        t.json :context, null: false, default: {}
      end

      t.datetime :finalized_at
      t.datetime :last_active_at

      t.timestamps

      t.index %i[saga_class correlation_id], unique: true
      t.index %i[saga_class current_state]
      # Plain (non-partial, adapter-portable) index: the sweeper's stranded-
      # compensating scan filters current_state cross-class, which neither
      # of the above compound indexes serves.
      t.index :current_state
      # Retention/dashboard filter finalized vs active in SQL (finalized_at
      # IS [NOT] NULL) without loading each saga class to ask terminal?.
      t.index :finalized_at
    end

    create_table :saga_forge_events, id: primary_key_type do |t|
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      # Lone-column index on saga_forge_state_id intentionally omitted:
      # the [saga_forge_state_id, created_at] index below covers left-prefix lookups.
      t.references :saga_forge_state, type: foreign_key_type,
        foreign_key: {to_table: :saga_forge_states}, index: false

      t.string :event_name, null: false
      t.integer :status, null: false, default: 0
      t.integer :stall_count, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :last_processed_at

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

      # Structural idempotency: a saga instance handles each event name at
      # most once (forward-only, no stay), so this tuple IS the dedup key —
      # webhook redeliveries and saga-to-saga fan-in no-op at the index.
      t.index %i[saga_class correlation_id event_name], unique: true
      t.index %i[saga_class correlation_id status]
      t.index %i[status created_at]
      t.index %i[saga_forge_state_id created_at]
    end
  end

  private

  # Explicit config wins; otherwise the app's config.generators setting;
  # otherwise Rails' create_table default (the :primary_key sentinel). See
  # SagaForge.primary_key_type.
  def primary_key_type
    SagaForge.primary_key_type
  end

  # t.references needs a concrete column type; :primary_key is only a valid
  # value for create_table's `id:` option, so resolve that sentinel to :bigint
  # here (mirrors what create_table would have picked for the referenced id).
  def foreign_key_type
    (primary_key_type == :primary_key) ? :bigint : primary_key_type
  end
end

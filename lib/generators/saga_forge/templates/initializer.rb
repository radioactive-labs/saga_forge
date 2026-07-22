SagaForge.configure do |config|
  # === Multi-database (optional) ===
  # Put saga_forge's two tables on a named database from database.yml.
  # Leaving this commented keeps them on the primary database.
  # config.database = :saga_forge
  #
  # Escape hatch for custom roles/shards — a raw connects_to hash (wins over
  # config.database):
  # config.connects_to = {database: {writing: :saga_forge, reading: :saga_forge_replica}}

  # === Engine tuning (defaults shown) ===
  # config.stall_wait     = 3.seconds   # early-event queue-spin wait
  # config.stall_budget   = 3           # spins before an event parks as stalled
  # config.sweep_interval = 30.seconds  # SweeperJob cadence (schedule it yourself)
  # config.retention      = 90.days     # processed-event pruning window (RetentionJob)
  # config.job_queue      = :sagas
  # config.primary_key_type = :uuid     # engine tables' PK type (default: host app convention)
end

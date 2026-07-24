module SagaForge
  class Configuration
    attr_accessor :stall_wait, :stall_budget, :sweep_interval, :retention,
      :job_queue, :database, :connects_to, :primary_key_type
    attr_writer :maintenance_queue

    def initialize
      @stall_wait = 3.seconds
      @stall_budget = 3
      @sweep_interval = 30.seconds
      @retention = 90.days
      @job_queue = :default
      @maintenance_queue = nil
      @database = nil
      @connects_to = nil
      @primary_key_type = nil
    end

    # Housekeeping jobs (sweeper, retention) default to the hot-path queue so
    # single-queue setups need no configuration; set explicitly to drain
    # recovery/pruning work on a separate (typically lower-priority) queue.
    def maintenance_queue
      @maintenance_queue || @job_queue
    end

    # Which named database the generators should target when no --database
    # flag is given: explicit database name, else the connects_to writing role.
    def migrations_database
      database || connects_to&.dig(:database, :writing)
    end
  end
end

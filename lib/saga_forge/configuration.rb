module SagaForge
  class Configuration
    attr_accessor :stall_wait, :stall_budget, :sweep_interval, :retention,
      :job_queue, :database, :connects_to, :primary_key_type

    def initialize
      @stall_wait = 3.seconds
      @stall_budget = 3
      @sweep_interval = 30.seconds
      @retention = 90.days
      @job_queue = :sagas
      @database = nil
      @connects_to = nil
      @primary_key_type = nil
    end

    # Which named database the generators should target when no --database
    # flag is given: explicit database name, else the connects_to writing role.
    def migrations_database
      database || connects_to&.dig(:database, :writing)
    end
  end
end

module SagaForge
  # The external entry point: INSERTs join any open transaction on the
  # engine connection; enqueues happen right after in plain code. The pending
  # row is the obligation, the enqueue a hint, the sweeper the guarantee.
  #
  # Idempotency is structural: the (saga_class, correlation_id, event_name)
  # unique index no-ops a duplicate delivery. A forward-only saga handles each
  # event name at most once, so a second delivery is always a duplicate.
  class Publisher
    class << self
      def publish(event_name, payload:)
        if SagaForge.within_saga_execution?
          raise UnstagedPublishError,
            "SagaForge.publish called inside saga execution — use saga.publish (staged, delivered on commit)"
        end

        attrs_list = Router.resolve(event_name, payload)
        return [] if attrs_list.empty?

        rows = attrs_list.filter_map { |attrs| insert_row(attrs) }
        rows.each { |row| ExecutionJob.perform_later(row.id) }
        rows
      end

      private

      # On Postgres, a failed INSERT (the unique-index violation) poisons the
      # server-side transaction — every subsequent statement, including the
      # caller's own COMMIT, would fail. The savepoint survives that abort for
      # the no-op'd duplicate; it nests inside whatever transaction is already
      # open and rolls back with its parent. The spec's "inserts join the
      # caller's transaction" guarantee holds: a successful insert still lives
      # and dies with the ambient transaction.
      def insert_row(attrs)
        ApplicationRecord.transaction(requires_new: true) do
          Event.create!(attrs)
        end
      rescue ActiveRecord::RecordNotUnique
        nil # duplicate delivery — the structural unique index no-ops it
      end
    end
  end
end

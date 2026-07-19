module SagaForge
  # The external entry point: INSERTs join any open transaction on the
  # engine connection; enqueues happen right after in plain code. The pending
  # row is the obligation, the enqueue a hint, the sweeper the guarantee.
  class Publisher
    class << self
      def publish(event_name, event_id:, payload:)
        if SagaForge.within_saga_execution?
          raise UnstagedPublishError,
            "SagaForge.publish called inside saga execution — use saga.publish (staged, delivered on commit)"
        end

        attrs_list = Router.resolve(event_name, payload)
        return [] if attrs_list.empty?

        event_id ||= digest_id(event_name, payload)
        rows = attrs_list.filter_map { |attrs| insert_row(attrs.merge(event_id: event_id)) }
        rows.each { |row| ExecutionJob.perform_later(row.id) }
        rows
      end

      # Deterministic only for JSON-primitive payload values (strings,
      # numbers, booleans, nil, and nested hashes/arrays thereof); NaN/
      # Infinity aren't valid JSON and make JSON.generate raise
      # JSON::GeneratorError — fail-fast by design rather than silently
      # hashing something that can't round-trip.
      def digest_id(event_name, payload)
        "digest:#{event_name}:#{Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload)))}"
      end

      private

      # On Postgres, a failed INSERT (the unique-index violation) poisons the
      # server-side transaction — every subsequent statement, including the
      # caller's own COMMIT, would fail with PG::InFailedSqlTransaction. The
      # savepoint here exists ONLY to survive that abort-on-error semantics
      # for the no-op'd duplicate; it nests inside whatever transaction is
      # already open (or opens its own single-statement one if there isn't
      # one) and rolls back with its parent on any outer rollback. This does
      # NOT detach the row from the caller's transaction — the spec's
      # "inserts join the caller's transaction" guarantee holds: a successful
      # insert here still lives and dies with the ambient transaction.
      def insert_row(attrs)
        ApplicationRecord.transaction(requires_new: true) do
          Event.create!(attrs)
        end
      rescue ActiveRecord::RecordNotUnique
        nil # duplicate delivery (e.g. webhook redelivery) — the unique index no-ops it
      end

      def deep_sort(obj)
        case obj
        when Hash then obj.map { |k, v| [k.to_s, deep_sort(v)] }.sort.to_h
        when Array then obj.map { |v| deep_sort(v) }
        else obj
        end
      end
    end
  end
end

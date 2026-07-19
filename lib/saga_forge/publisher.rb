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

      def digest_id(event_name, payload)
        "digest:#{event_name}:#{Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload)))}"
      end

      private

      def insert_row(attrs)
        Event.create!(attrs)
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

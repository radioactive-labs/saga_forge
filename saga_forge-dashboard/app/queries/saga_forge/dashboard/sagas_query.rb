module SagaForge
  module Dashboard
    # Keyset pagination over one saga class's State rows. Orders by PK desc,
    # pages with id < / > cursor, never COUNTs. Virtual filters compose the
    # engine's derived scopes (stalled/suspended/compensating).
    class SagasQuery
      DEFAULT_PER = 50
      MAX_PER = 200

      def initialize(saga_class:, filter: nil, correlation: nil, before: nil, after: nil, per: DEFAULT_PER)
        @saga_class = saga_class
        @filter = filter.presence
        @correlation = correlation.presence
        @before = before.presence&.to_i
        @after = after.presence&.to_i
        @per = per.to_i.clamp(1, MAX_PER)
      end

      def records
        load
        @records
      end
      attr_reader :per

      def has_next? # older rows remain
        load
        @has_next
      end

      def has_prev? # newer rows remain
        load
        @has_prev
      end

      def next_cursor = records.last&.id
      def prev_cursor = records.first&.id

      private

      def base
        SagaForge::State.for_saga(@saga_class)
      end

      def filtered
        s = case @filter
        when "stalled" then base.stalled
        when "suspended" then base.suspended
        when "compensating" then base.compensating
        when "finalized" then base.finalized
        when "active" then base.active
        when nil, "", "all" then base
        else base.where(current_state: @filter)
        end
        if @correlation
          s = s.where("correlation_id LIKE ?", "#{SagaForge::State.sanitize_sql_like(@correlation)}%")
        end
        s
      end

      def load
        return if @loaded
        @loaded = true
        col = "#{SagaForge::State.table_name}.id"
        if @after
          rows = filtered.where("#{col} > ?", @after).order(id: :asc).limit(@per + 1).to_a
          @has_prev = rows.size > @per
          @records = rows.first(@per).reverse
          # Reaching this page via a real prev_cursor means older rows exist (this
          # page came from one); a stale/deleted-anchor cursor just self-heals to
          # the first page on the next click, so hardcoding true here is safe.
          @has_next = true
        else
          scope = filtered
          scope = scope.where("#{col} < ?", @before) if @before
          rows = scope.order(id: :desc).limit(@per + 1).to_a
          @has_next = rows.size > @per
          @records = rows.first(@per)
          @has_prev = @before.present?
        end
      end
    end
  end
end

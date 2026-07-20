module SagaForge
  module Dashboard
    # Fleet-wide breakdown: how many instances of each saga class sit in each
    # current_state. One GROUP BY scan feeds the whole "classes" frame, the
    # honest cost of a "totals across everything" view (unlike StatsQuery's
    # per-class counts, a fleet-wide total can't be capped the way a single
    # class's hot list can).
    class OverviewQuery
      # {saga_class => {current_state => count}}. current_state is a plain
      # string column here (no enum), so the GROUP BY key is already the raw
      # label, no enum int-vs-label normalization needed.
      def rows
        SagaForge::State.group(:saga_class, :current_state).count
          .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((klass, state), n), acc|
            acc[klass][state] = n
          end
      end

      # Fleet-wide card totals, reusing the engine's own derived scopes
      # (State.stalled/.suspended/.compensating) rather than reimplementing
      # their subqueries here, same discipline as SagasQuery/StatsQuery.
      def totals
        {
          all: SagaForge::State.count,
          stalled: SagaForge::State.stalled.count,
          suspended: SagaForge::State.suspended.count,
          compensating: SagaForge::State.compensating.count
        }
      end
    end
  end
end

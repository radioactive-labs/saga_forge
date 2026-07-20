module SagaForge
  module Dashboard
    class StatsQuery
      CAP = 5000

      def initialize(saga_class:)
        @saga_class = saga_class
      end

      def counts
        base = SagaForge::State.for_saga(@saga_class)
        {
          all: capped(base),
          stalled: capped(base.stalled),
          suspended: capped(base.suspended),
          compensating: capped(base.compensating)
        }
      end

      def label(n) = (n >= CAP) ? "#{CAP}+" : n.to_s

      private

      def capped(relation)
        SagaForge::State.from(relation.select(:id).limit(CAP), :capped).count
      end
    end
  end
end

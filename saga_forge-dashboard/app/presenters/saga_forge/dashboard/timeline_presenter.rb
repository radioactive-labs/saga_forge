module SagaForge
  module Dashboard
    # One chronological stream for a saga instance: the event ledger merged with
    # the compensation progress the engine records in context["__saga_forge"].
    # The engine does not pre-merge these, so the dashboard owns it.
    class TimelinePresenter
      Entry = Struct.new(:at, :kind, :label, :status, :detail)

      def initialize(state)
        @state = state
      end

      def entries
        rows = @state.history.map do |e|
          Entry.new(at: e.created_at, kind: :event, label: e.event_name, status: e.status,
            detail: {payload: e.payload, attempts: e.attempts, stall_count: e.stall_count,
                     retry_budgets: e.retry_budgets, error: e.error})
        end
        rows + compensation_entries
      end

      # Compensation entries have no per-step timestamp recorded by the engine
      # (only the aggregate "compensated" list survives), so they're pinned to
      # state.updated_at and sorted after events sharing that same instant.
      def sorted = entries.sort_by { |e| [e.at || Time.at(0), (e.kind == :event) ? 0 : 1] }

      private

      def meta = @state.context["__saga_forge"] || {}

      def compensation_entries
        done = meta["compensated"] || []
        list = done.map do |name|
          Entry.new(at: @state.updated_at, kind: :compensation, label: name, status: "processed",
            detail: {attempts: meta.dig("comp_attempts", name)})
        end
        if (err = meta["comp_error"])
          list << Entry.new(at: @state.updated_at, kind: :compensation, label: err["name"], status: "failed",
            detail: {error: err})
        end
        list
      end
    end
  end
end

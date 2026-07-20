module SagaForge
  module Dashboard
    # One chronological stream for a saga instance: the event ledger merged with
    # the compensation progress the engine records in context["__saga_forge"].
    # The engine does not pre-merge these, so the dashboard owns it.
    class TimelinePresenter
      # index: this entry's position in its own source array (the event ledger,
      # or the compensated/comp_error list) — a tertiary sort key so #sorted is
      # deterministic. Array#sort_by is not guaranteed stable, and every
      # compensation entry shares the same synthetic `at` (see below), so
      # without this tiebreak a multi-step compensation can render out of its
      # actual (recorded) order with no indication anything is wrong.
      Entry = Struct.new(:at, :kind, :label, :status, :detail, :index)

      # A stay-loop saga can accumulate thousands of event rows; rendering all
      # of them (each with a full payload/backtrace) doesn't scale. Cap to the
      # most recent MAX_ENTRIES, mirroring StatsQuery::CAP's spirit. Compensation
      # entries are small (derived from context, not a separate table) and are
      # never capped.
      MAX_ENTRIES = 500

      def initialize(state)
        @state = state
      end

      def entries
        @entries ||= event_entries + compensation_entries
      end

      def sorted
        @sorted ||= entries.sort_by { |e| [e.at || Time.at(0), (e.kind == :event) ? 0 : 1, e.index] }
      end

      # True when the event ledger was truncated to the most recent MAX_ENTRIES.
      # Side-effect-free (derived from total_event_count alone) so it gives the
      # right answer even if called before entries/sorted have run.
      def truncated? = total_event_count > MAX_ENTRIES

      def total_event_count = @total_event_count ||= @state.events.count

      private

      def meta = @state.context["__saga_forge"] || {}

      def event_entries
        rows = @state.history.last(MAX_ENTRIES)
        rows.each_with_index.map do |e, i|
          Entry.new(at: e.created_at, kind: :event, label: e.event_name, status: e.status,
            detail: {payload: e.payload, attempts: e.attempts, stall_count: e.stall_count,
                     retry_budgets: e.retry_budgets, error: e.error}, index: i)
        end
      end

      def compensation_entries
        done = meta["compensated"] || []
        list = done.each_with_index.map do |name, i|
          Entry.new(at: @state.updated_at, kind: :compensation, label: name, status: "processed",
            detail: {attempts: meta.dig("comp_attempts", name)}, index: i)
        end
        if (err = meta["comp_error"])
          list << Entry.new(at: @state.updated_at, kind: :compensation, label: err["name"], status: "failed",
            detail: {error: err}, index: list.size)
        end
        list
      end
    end
  end
end

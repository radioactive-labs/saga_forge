module SagaForge
  module Dashboard
    class ActionsController < BaseController
      def retry_stalled = run { @state.retry_stalled! }

      def resume = run { @state.resume! }

      def compensate = run { @state.compensate! }

      def cancel = run { @state.cancel!(reason: params[:reason].presence || "operator") }

      # Fans the retry/resume out to a background job scoped to one saga
      # class — the stalled/suspended lists are cross-class, so the class is
      # named explicitly rather than inferred from a single instance.
      def bulk
        klass = SagaForge::Router.saga_classes.find { |k| k.name == params[:saga_class] }
        return redirect_back(fallback_location: root_path, alert: "Unknown saga class.") unless klass

        BulkRecoveryJob.perform_later(klass.name, params[:mode])
        redirect_back(fallback_location: root_path, notice: "Bulk #{params[:mode]} enqueued for #{klass.name}.")
      end

      private

      # Shared per-instance action shape: find the state, run the operator
      # method, and flash based on its boolean return — the operator methods
      # are status-scoped no-ops (rather than raising) when there's nothing
      # eligible, so "false" means "nothing to do", not a failure.
      def run
        @state = SagaForge::State.find(params[:id])
        did = yield
        redirect_to saga_path(@state), notice: (did ? "Done." : "Nothing to do.")
      end
    end
  end
end

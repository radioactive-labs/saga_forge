module SagaForge
  module Dashboard
    class SagasController < BaseController
      def index
        @saga_classes = SagaForge::Router.saga_classes.sort_by(&:name)
        @saga_class = (params[:class].presence && @saga_classes.find { |k| k.name == params[:class] }) || @saga_classes.first
        return render :empty unless @saga_class

        @stats = StatsQuery.new(saga_class: @saga_class)
        @query = SagasQuery.new(saga_class: @saga_class, filter: params[:filter],
          correlation: params[:q], before: params[:before], after: params[:after],
          per: SagaForge::Dashboard.config.page_size)
      end

      def show
        @state = SagaForge::State.find(params[:id])
        @timeline = TimelinePresenter.new(@state)
        @context = ContextPresenter.new(@state)
        @stalled = @state.events.stalled.exists?
        @suspended = @state.events.failed.exists?
        @comp_error = @state.context.dig("__saga_forge", "comp_error")
      end
    end
  end
end

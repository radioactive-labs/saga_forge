module SagaForge
  module Dashboard
    # The per-class state-machine graph (chain + best-effort jump/stay edges),
    # with one saga instance's status overlaid onto the nodes when a
    # correlation_id is given. An unknown saga class is a routing fact of
    # life (typo'd URL, renamed/removed class), not a 500 — it renders a
    # friendly empty state instead.
    class DefinitionsController < BaseController
      def show
        # Opt out of the auto-refresh region morph: reconciling the region's
        # HTML wipes the live Cytoscape canvas (injected <script>s don't
        # re-run), leaving a blank graph. This page reloads fully instead.
        @sf_disable_polling = true

        @saga_class = SagaForge::Router.saga_classes.find { |k| k.name == params[:class] }
        return render :missing unless @saga_class

        definition = @saga_class.definition
        @state = params[:correlation_id].present? ? @saga_class.find_by_correlation(params[:correlation_id]) : nil
        @graph = SagaGraph.new(definition.to_graph, definition, @state).to_h
      end
    end
  end
end

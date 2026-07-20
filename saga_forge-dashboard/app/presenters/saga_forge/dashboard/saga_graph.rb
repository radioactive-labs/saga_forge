module SagaForge
  module Dashboard
    # Turns a Definition#to_graph (structured nodes + typed chain/jump/stay
    # edges) into Cytoscape.js "elements", optionally overlaying one saga
    # instance's status onto the nodes. Rendering-only: no DB, no analysis.
    class SagaGraph
      RANK = {"failed" => 3, "stalled" => 2, "processed" => 1}.freeze

      def initialize(graph, definition, state = nil)
        @graph = graph # SagaForge::Dashboard::Graph
        @definition = definition
        @state = state
      end

      def to_h
        {nodes: node_elements, edges: edge_elements}
      end

      private

      # Each event is attributed to a node via Definition#state_for_event,
      # the EXACT handler table, not a scan of edge labels (which are only
      # best-effort for jump/stay and would misattribute events on states
      # reached solely by a computed transition). A state colors to the worst
      # of its events' statuses (failed > stalled > processed; pending events
      # don't color anything). The current state always wins as :active,
      # regardless of what its own events say: it's "in progress", not
      # judged by history.
      def status_map
        return {} unless @state
        @status_map ||= begin
          by_node = {}
          @state.events.each do |e|
            node = @definition.state_for_event(e.event_name)&.to_s
            next unless node
            rank = RANK[e.status.to_s] || 0
            next if rank.zero?
            by_node[node] = e.status.to_s if rank > (RANK[by_node[node]] || 0)
          end
          by_node[@state.current_state.to_s] = "active"
          by_node
        end
      end

      def node_elements
        @graph.nodes.map do |n|
          status = status_map[n.id] || "none"
          {data: {id: n.id, label: n.label}, classes: "kind-#{n.kind} status-#{status}"}
        end
      end

      def edge_elements
        @graph.edges.each_with_index.map do |e, i|
          {data: {id: "e#{i}", source: e.from, target: e.to, label: e.label.to_s}, classes: "kind-#{e.kind}"}
        end
      end
    end
  end
end

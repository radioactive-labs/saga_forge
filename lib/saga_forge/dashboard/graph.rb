module SagaForge
  module Dashboard
    # Structured, serializable graph derived from a compiled Definition. The
    # core gem owns this shape so any consumer (the dashboard, a doc generator)
    # gets the same typed representation instead of parsing the mermaid string.
    Graph = Struct.new(:nodes, :edges) do
      def to_h = {nodes: nodes.map(&:to_h), edges: edges.map(&:to_h)}
    end

    # kind: :start | :state | :terminal
    Node = Struct.new(:id, :label, :kind) do
      def to_h = {id: id, label: label, kind: kind}
    end

    # kind: :chain (complete) | :jump (best-effort)
    Edge = Struct.new(:from, :to, :kind, :label) do
      def to_h = {from: from, to: to, kind: kind, label: label}
    end
  end
end

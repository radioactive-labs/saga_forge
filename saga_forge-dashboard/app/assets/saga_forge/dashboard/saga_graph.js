// Renders a saga's state-machine graph (Definition#to_graph: start/state/
// terminal nodes, chain/jump/stay edges) with Cytoscape + dagre, optionally
// overlaid with one saga instance's status. Reads the graph as JSON from
// #sf-graph[data-graph] (structured elements, no text grammar) and paints
// kind (node shape) + overlay status (fill/border) + edge kind (chain solid /
// jump dashed / stay self-loop). Interactive: pan/zoom, and tapping a
// node/edge shows its details and highlights its neighborhood.
(function () {
  var el = document.getElementById("sf-graph");
  if (!el || typeof cytoscape === "undefined") return;
  if (window.cytoscapeDagre) {
    try { cytoscape.use(window.cytoscapeDagre); } catch (e) { /* already registered */ }
  }

  var graph;
  try { graph = JSON.parse(el.getAttribute("data-graph")); } catch (e) { return; }

  // Escape before writing into innerHTML: node labels are state names and
  // edge labels are event names (Ruby symbols/strings from the saga's
  // declared DSL), harmless in practice, but tap details render them as
  // HTML, so escape defensively regardless.
  var ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"};
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return ESC[c]; }); }

  // Node shape per graph-node kind (a legend in the view maps these back to
  // names).
  var SHAPE = {start: "ellipse", state: "round-rectangle", terminal: "round-tag"};

  // [fill, border, text] per overlay status. none is muted so the states an
  // instance hasn't touched recede behind the ones it has.
  var COLOR = {
    active: ["#eef0fc", "#4650c8", "#31358f"],
    processed: ["#ecfdf5", "#10b981", "#065f46"],
    stalled: ["#fffbeb", "#f59e0b", "#9a3412"],
    failed: ["#fff1f2", "#f43f5e", "#9f1239"],
    none: ["#fafafa", "#d4d4d8", "#52525b"]
  };

  graph.nodes.forEach(function (n) { n.data.display = n.data.label || n.data.id; });

  var style = [
    {
      selector: "node",
      style: {
        "label": "data(display)", "text-wrap": "wrap", "text-max-width": "150px",
        "text-valign": "center", "text-halign": "center", "text-justification": "center",
        "font-family": "ui-sans-serif, system-ui, sans-serif", "font-size": "11px",
        "line-height": 1.35, "width": "150px", "height": "label",
        "padding": "12px", "shape": "round-rectangle", "corner-radius": "10px",
        "border-width": 1.5, "background-color": "#fff", "border-color": "#e4e4e7",
        "color": "#3f3f46", "text-outline-width": 0
      }
    },
    {selector: "edge", style: {
      // Label sits near the TARGET (not mid-edge), so several edges leaving
      // the same node don't stack their labels on top of each other.
      "target-label": "data(label)", "target-text-offset": "42px",
      "font-size": "9px", "font-family": "ui-sans-serif, system-ui, sans-serif",
      "color": "#64748b", "curve-style": "bezier",
      "width": 1.5, "line-color": "#cbd5e1", "target-arrow-shape": "triangle",
      "target-arrow-color": "#94a3b8", "arrow-scale": 0.9,
      "text-background-color": "#fff", "text-background-opacity": 1,
      "text-background-padding": "3px", "text-background-shape": "round-rectangle",
      "text-border-color": "#e2e8f0", "text-border-width": 1, "text-border-opacity": 1,
      "text-max-width": "120px", "text-wrap": "ellipsis", "text-events": "yes"
    }},
    {selector: "edge.kind-chain", style: {
      "curve-style": "taxi", "taxi-direction": "downward", "taxi-turn": "40%", "taxi-turn-min-distance": "8px"
    }},
    {selector: "edge.kind-jump", style: {
      "line-style": "dashed", "line-color": "#a78bfa", "target-arrow-color": "#8b5cf6", "color": "#7c3aed"
    }},
    {selector: "edge.kind-stay", style: {
      // Self-loop: source === target, rendered as a loop off the node
      // regardless of what the dagre layout otherwise does with the node.
      "curve-style": "bezier", "loop-direction": "-30deg", "loop-sweep": "50deg",
      "control-point-step-size": 40, "line-color": "#94a3b8", "target-arrow-color": "#94a3b8"
    }},
    {selector: "node.dim", style: {"opacity": 0.2}},
    {selector: "edge.dim", style: {"opacity": 0.12}},
    {selector: "node.focus", style: {"border-width": 3}},
    {selector: "node.hover", style: {"border-width": 2.5}}
  ];
  Object.keys(SHAPE).forEach(function (k) {
    style.push({selector: "node.kind-" + k, style: {"shape": SHAPE[k]}});
  });
  Object.keys(COLOR).forEach(function (s) {
    style.push({selector: "node.status-" + s, style: {
      "background-color": COLOR[s][0], "border-color": COLOR[s][1], "color": COLOR[s][2]
    }});
  });
  // start is the machine's single entry point, visually distinct, like an
  // endpoint marker rather than a state.
  style.push({selector: "node.kind-start", style: {
    "background-color": "#18181b", "border-color": "#18181b", "color": "#fff",
    "width": "label", "font-size": "10px", "font-weight": "600", "padding": "8px"
  }});
  style.push({selector: "node.kind-terminal", style: {"font-weight": "600"}});

  var cy = cytoscape({
    container: el,
    elements: graph,
    style: style,
    layout: {
      name: "dagre", rankDir: "TB", nodeSep: 42, rankSep: 70, edgeSep: 18,
      ranker: "network-simplex", padding: 30
    },
    minZoom: 0.25, maxZoom: 2.5, wheelSensitivity: 0.25, autoungrabify: true
  });
  cy.ready(function () { cy.fit(cy.elements(), 36); });

  var detail = document.getElementById("sf-graph-detail");
  function hint() {
    if (detail) detail.innerHTML = '<span class="text-zinc-400">Tap a node or edge to inspect it. Scroll to zoom, drag to pan.</span>';
  }
  function clearFocus() { cy.elements().removeClass("dim focus"); hint(); }

  cy.on("mouseover", "node", function (e) { e.target.addClass("hover"); });
  cy.on("mouseout", "node", function (e) { e.target.removeClass("hover"); });

  cy.on("tap", "node", function (evt) {
    var n = evt.target, hood = n.closedNeighborhood();
    cy.elements().addClass("dim");
    hood.removeClass("dim");
    cy.nodes().removeClass("focus");
    n.addClass("focus");
    if (detail) {
      var d = n.data(), cls = n.classes() || [];
      var kind = (cls.join(" ").match(/kind-(\w+)/) || [])[1] || "";
      var status = (cls.join(" ").match(/status-(\w+)/) || [])[1] || "";
      detail.innerHTML =
        '<div class="font-medium text-zinc-800">' + esc(d.label || d.id) + "</div>" +
        '<div class="text-zinc-500">' + esc(kind) +
        (status && status !== "none" ? ' &middot; <span class="font-medium">' + esc(status) + "</span>" : "") + "</div>";
    }
  });
  cy.on("tap", "edge", function (evt) {
    var e = evt.target, cls = e.classes() || [];
    var kind = (cls.join(" ").match(/kind-(\w+)/) || [])[1] || "";
    var label = e.data("label");
    if (detail) {
      detail.innerHTML =
        '<div class="text-zinc-500">' + esc(kind) + " edge</div>" +
        (label ? '<div class="mt-0.5 font-mono text-[11px] text-zinc-700">' + esc(label) + "</div>" : "");
    }
  });
  cy.on("tap", function (evt) { if (evt.target === cy) clearFocus(); });
  hint();
})();

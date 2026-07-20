SagaForge::Dashboard::Engine.routes.draw do
  root to: "sagas#index"
  resources :sagas, only: %i[index show]

  # Fleet overview: a lazy-loaded turbo-frame shell (index) plus the frame it
  # loads (classes), which carries the one GROUP BY query in its own request.
  get "overview", to: "overview#index", as: :overview
  scope "overview", as: :overview do
    get "classes", to: "overview#classes"
  end
  resources :stalled, only: :index
  resources :suspended, only: :index

  # Explicit allowlist (mirrors AssetsController::TYPES) so unknown assets 404 at
  # the routing layer rather than reaching the controller.
  # Do NOT anchor this regex with \A/\z: the segment is already anchored by the
  # literal "assets/" prefix, and an inline \A/\z here would make the route
  # match nothing (a documented Rails routing gotcha). The controller's
  # exact-string TYPES lookup is the real gate; this regex is defense-in-depth.
  get "assets/:file", to: "assets#show", constraints: {
    file: /(dashboard\.(css|js)|turbo\.min\.js|cytoscape\.min\.js|dagre\.min\.js|cytoscape-dagre\.js|saga_graph\.js)/
  }
end

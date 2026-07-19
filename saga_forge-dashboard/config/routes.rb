SagaForge::Dashboard::Engine.routes.draw do
  root to: "sagas#index"
  resources :sagas, only: %i[index show]

  # Explicit allowlist (mirrors AssetsController::TYPES) so unknown assets 404 at
  # the routing layer rather than reaching the controller.
  get "assets/:file", to: "assets#show", constraints: {
    file: /(dashboard\.(css|js)|turbo\.min\.js|cytoscape\.min\.js|dagre\.min\.js|cytoscape-dagre\.js|saga_graph\.js)/
  }
end

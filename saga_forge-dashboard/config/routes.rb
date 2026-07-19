SagaForge::Dashboard::Engine.routes.draw do
  root to: "sagas#index"
  resources :sagas, only: %i[index show]
end

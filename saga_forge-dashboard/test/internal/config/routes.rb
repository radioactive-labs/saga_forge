Rails.application.routes.draw do
  mount SagaForge::Dashboard::Engine => "/saga_forge"
end

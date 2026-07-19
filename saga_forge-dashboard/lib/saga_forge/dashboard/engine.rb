require "rails/engine"

module SagaForge
  module Dashboard
    class Engine < ::Rails::Engine
      isolate_namespace SagaForge::Dashboard
    end
  end
end

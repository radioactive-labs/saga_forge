module SagaForge
  module Dashboard
    class SagasController < BaseController
      def index
        @saga_classes = SagaForge::Router.saga_classes
      end
    end
  end
end

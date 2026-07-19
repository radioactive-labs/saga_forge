module SagaForge
  # The router needs every saga class loaded to resolve recipients; lazy
  # autoloading in dev would silently drop recipients. Eager-load app/sagas
  # on each reload.
  class Railtie < Rails::Railtie
    initializer "saga_forge.eager_load_sagas" do |app|
      app.config.to_prepare do
        SagaForge::Router.reset!
        dir = Rails.root.join("app/sagas")
        Rails.autoloaders.main.eager_load_dir(dir.to_s) if dir.exist?
        SagaForge::Router.compile_all!
      end
    end
  end
end

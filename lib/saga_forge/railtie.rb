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
        # Force every registered class to compile its Definition now, so a
        # broken saga (bad DSL, missing correlate_by, etc.) crashes loudly at
        # boot/reload (§A.8) instead of surfacing as a silent skipped
        # recipient the first time something happens to publish its event.
        SagaForge::Router.saga_classes.each(&:definition)
      end
    end
  end
end

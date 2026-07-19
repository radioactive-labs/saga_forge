require Gem.loaded_specs["saga_forge"].full_gem_path + "/lib/generators/saga_forge/templates/install_saga_forge"

ActiveRecord::Schema.define(version: 1) do
  # The gem's install template is a Migration subclass; run its change set.
  InstallSagaForge.new.change
end

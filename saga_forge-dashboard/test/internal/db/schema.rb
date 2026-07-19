require Gem.loaded_specs["saga_forge"].full_gem_path + "/lib/generators/saga_forge/templates/install_saga_forge"

# NOTE: this replays only the initial install migration. If saga_forge ever
# ships a second migration, require and run it here too, or the dummy app's
# schema will silently drift from the gem's real schema.
ActiveRecord::Schema.define(version: 1) do
  # The gem's install template is a Migration subclass; run its change set.
  InstallSagaForge.new.change
end

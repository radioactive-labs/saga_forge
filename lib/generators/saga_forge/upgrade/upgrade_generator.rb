# frozen_string_literal: true

require "rails/generators/active_record/migration"
require_relative "../migration_actions"

module SagaForge
  # Brings an existing SagaForge installation up to the current schema by
  # copying any migrations the application does not already have. Applications
  # created with `saga_forge:install` on the current version already have
  # everything; older installs pick up any additive migrations added since.
  #
  #   rails generate saga_forge:upgrade
  #   rails db:migrate
  #
  # Multi-database aware: with --database (or config.database set in the
  # initializer), missing migrations are copied into db/NAME_migrate.
  class UpgradeGenerator < Rails::Generators::Base
    include ::ActiveRecord::Generators::Migration
    include SagaForge::Generators::MigrationActions

    source_root File.expand_path("../templates", __dir__)

    def start
      copy_saga_forge_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end
  end
end

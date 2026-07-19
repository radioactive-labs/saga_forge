require "rails/generators/base"

module SagaForge
  module Generators
    # Installs (and, after a gem upgrade, refreshes) SagaForge's engine migrations.
    # SagaForge keeps its migration in db/saga_forge_migrate rather than the
    # conventional db/migrate, so Rails never auto-appends it onto the host's
    # primary connection nor generates a generic install:migrations task: this
    # generator is the single install path. It is multi-database aware: it reads
    # config.database (set at install time) so a host that forgets the flag on a
    # later run still gets new migrations in the right place. Uses Rails' native
    # ActiveRecord::Migration.copy, so re-runs are idempotent (already-installed
    # migrations are skipped).
    class MigrationsGenerator < Rails::Generators::Base
      desc "Installs SagaForge's migrations. Multi-db setups (config.database or " \
           "--database) get them in db/NAME_migrate; otherwise the primary db/migrate."

      class_option :database, type: :string, aliases: "-d", default: nil, banner: "NAME",
        desc: "Install into db/NAME_migrate for this database " \
              "(defaults to config.database / connects_to)"

      def install_migrations
        database = options[:database].presence || SagaForge.config.migrations_database
        # The primary connection always migrates from db/migrate; only a separate
        # database gets its own db/<name>_migrate path.
        dir = (database.nil? || database.to_s == "primary") ? "db/migrate" : "db/#{database}_migrate"
        copied = ActiveRecord::Migration.copy(
          File.join(destination_root, dir),
          {"saga_forge" => File.expand_path("../../../../db/saga_forge_migrate", __dir__)}
        )
        if copied.any?
          say_status :installed, "#{copied.size} SagaForge migration(s) into #{dir}", :green
        else
          say_status :identical, "SagaForge migrations already present in #{dir}", :blue
        end
      end
    end
  end
end

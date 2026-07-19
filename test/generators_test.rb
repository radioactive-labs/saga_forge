require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/saga_forge/migrations/migrations_generator"
require "generators/saga_forge/install/install_generator"

module SagaForge
  class MigrationsGeneratorTest < Rails::Generators::TestCase
    tests SagaForge::Generators::MigrationsGenerator
    destination File.expand_path("tmp/generator", __dir__)
    setup :prepare_destination
    setup { SagaForge.reset_configuration! }

    def saga_forge_tables_migration(dir)
      Dir[File.join(destination_root, dir, "*.rb")]
        .find { |f| File.basename(f).match?(/\A\d+_create_saga_forge_tables\.saga_forge\.rb\z/) }
    end

    test "installs into the primary db/migrate by default" do
      run_generator
      migration = saga_forge_tables_migration("db/migrate")
      assert migration, "copies the engine migration to db/migrate"
      assert_match(/This migration comes from saga_forge/, File.read(migration))
      assert_empty Dir[File.join(destination_root, "db/saga_forge_migrate/*.rb")]
    end

    test "installs into db/NAME_migrate with --database" do
      run_generator ["--database=saga"]
      assert saga_forge_tables_migration("db/saga_migrate"), "copies into the database's own path"
      assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
    end

    test "treats --database=primary as the primary db/migrate" do
      run_generator ["--database=primary"]
      assert saga_forge_tables_migration("db/migrate"), "primary is not db/primary_migrate"
      assert_empty Dir[File.join(destination_root, "db/primary_migrate/*.rb")]
    end

    test "falls back to config.database when no flag is given" do
      SagaForge.config.database = :billing
      run_generator
      assert saga_forge_tables_migration("db/billing_migrate"), "reads config so re-runs target the right db"
    end

    test "re-running is idempotent" do
      run_generator
      first = Dir[File.join(destination_root, "db/migrate/*.rb")].sort
      run_generator
      second = Dir[File.join(destination_root, "db/migrate/*.rb")].sort
      assert_equal first, second, "second run copies nothing new"
      assert_equal 1, second.size
    end
  end

  class InstallGeneratorTest < Rails::Generators::TestCase
    tests SagaForge::Generators::InstallGenerator
    destination File.expand_path("tmp/generator", __dir__)
    setup :prepare_destination
    setup { SagaForge.reset_configuration! }

    test "creates the initializer" do
      run_generator
      assert_file "config/initializers/saga_forge.rb", /SagaForge\.configure/
    end

    test "without --database leaves config.database commented and installs into db/migrate" do
      run_generator
      assert_file "config/initializers/saga_forge.rb", /^\s*#\s*config\.database\s*=/
      assert Dir[File.join(destination_root, "db/migrate/*_create_saga_forge_tables.saga_forge.rb")].any?,
        "installs the migration into the primary db/migrate"
      assert_empty Dir[File.join(destination_root, "db/saga_forge_migrate/*.rb")]
    end

    test "with --database sets config.database and installs migrations into db/NAME_migrate" do
      output = run_generator ["--database=saga"]
      assert_file "config/initializers/saga_forge.rb", /^\s*config\.database = :saga\s*$/

      migrations = Dir[File.join(destination_root, "db/saga_migrate/*.rb")].sort
      assert_equal 1, migrations.size
      tables = migrations.find { |f| File.basename(f).match?(/\A\d+_create_saga_forge_tables\.saga_forge\.rb\z/) }
      assert tables, "copies the saga_forge tables migration (re-timestamped, scope-tagged)"
      body = File.read(tables)
      assert_match(/create_table :saga_forge_states/, body)
      assert_match(/This migration comes from saga_forge/, body, "native copy tags the origin")

      assert_match(/migrations_paths/, output)
      assert_match(/db:migrate:saga/, output)
    end
  end
end

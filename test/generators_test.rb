require "test_helper"
require "rails/generators"
require "tmpdir"
require File.expand_path("../lib/generators/saga_forge/install/install_generator.rb", __dir__)
require File.expand_path("../lib/generators/saga_forge/upgrade/upgrade_generator.rb", __dir__)

class GeneratorsTest < SagaForge::TestCase
  def migrations_in(dir)
    Dir.glob(File.join(dir, "db", "migrate", "*.rb")).map { |f| File.basename(f).sub(/\A\d+_/, "") }.sort
  end

  def run_generator(klass, dir, args = [])
    silence_stream($stdout) { klass.start(args, destination_root: dir) }
  end

  # Minitest doesn't ship silence_stream everywhere; provide a tiny shim.
  def silence_stream(stream)
    old = stream.dup
    stream.reopen(File::NULL)
    stream.sync = true
    yield
  ensure
    stream.reopen(old)
    old.close
  end

  def test_a_migration_whose_name_merely_ends_in_a_gem_migration_name_does_not_suppress_the_copy
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
      File.write(File.join(dir, "db", "migrate", "20200101000000_my_install_saga_forge.rb"), "# host decoy")

      run_generator(SagaForge::InstallGenerator, dir)

      assert_includes migrations_in(dir), "install_saga_forge.rb",
        "a host migration ending in a gem migration's name must not count as installed"
    end
  end

  def test_install_copies_the_migration
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir)

      assert_equal ["install_saga_forge.rb"], migrations_in(dir),
        "install should copy the saga_forge migration"
    end
  end

  def test_install_is_idempotent
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir)
      run_generator(SagaForge::InstallGenerator, dir)

      # Re-running must not duplicate the migration.
      assert_equal 1, Dir.glob(File.join(dir, "db", "migrate", "*.rb")).size,
        "re-running install must not create a duplicate migration"
    end
  end

  def test_upgrade_copies_nothing_when_already_installed
    Dir.mktmpdir do |dir|
      # An app already installed on the current version has the migration.
      FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
      File.write(File.join(dir, "db", "migrate", "20260719000001_install_saga_forge.rb"), "# existing\n")

      run_generator(SagaForge::UpgradeGenerator, dir)

      names = migrations_in(dir)
      assert_equal ["install_saga_forge.rb"], names
      assert_equal 1, names.count("install_saga_forge.rb"),
        "upgrade must not re-copy a migration that already exists"
    end
  end

  def test_upgrade_copies_the_missing_migration_on_a_bare_app
    Dir.mktmpdir do |dir|
      # A bare app (no prior saga_forge install) is missing everything.
      run_generator(SagaForge::UpgradeGenerator, dir)

      assert_equal ["install_saga_forge.rb"], migrations_in(dir),
        "upgrade should bring a bare app up to the current schema"
    end
  end

  def test_install_with_database_targets_db_name_migrate_and_records_it
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir, ["--database=saga"])

      assert_equal 1, Dir.glob(File.join(dir, "db", "saga_migrate", "*.rb")).size,
        "the migration should land in db/saga_migrate"
      assert_empty Dir.glob(File.join(dir, "db", "migrate", "*.rb")),
        "nothing should land in db/migrate when --database is given"

      initializer = File.read(File.join(dir, "config", "initializers", "saga_forge.rb"))
      assert_match(/^  config\.database = :saga$/, initializer,
        "install must record --database in the initializer for later upgrade runs")
    end
  end

  def test_install_generates_commented_initializer_by_default
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir)

      initializer = File.read(File.join(dir, "config", "initializers", "saga_forge.rb"))
      assert_match(/# config\.database = :saga_forge/, initializer)
      refute_match(/^  config\.database =/, initializer,
        "no active config.database line without --database")
    end
  end

  def test_install_with_primary_database_behaves_like_no_flag
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir, ["--database=primary"])

      assert_equal 1, Dir.glob(File.join(dir, "db", "migrate", "*.rb")).size,
        "--database=primary must install into db/migrate like the default"

      initializer = File.read(File.join(dir, "config", "initializers", "saga_forge.rb"))
      refute_match(/^  config\.database =/, initializer,
        "--database=primary must not activate config.database (it would trigger connects_to at boot)")
    end
  end

  def test_install_with_database_is_idempotent
    Dir.mktmpdir do |dir|
      run_generator(SagaForge::InstallGenerator, dir, ["--database=saga"])
      run_generator(SagaForge::InstallGenerator, dir, ["--database=saga"])

      assert_equal 1, Dir.glob(File.join(dir, "db", "saga_migrate", "*.rb")).size,
        "re-running install --database must not duplicate the migration"
    end
  end

  def test_install_falls_back_to_config_database
    Dir.mktmpdir do |dir|
      SagaForge.configure { |c| c.database = :billing }

      run_generator(SagaForge::InstallGenerator, dir)

      assert_equal 1, Dir.glob(File.join(dir, "db", "billing_migrate", "*.rb")).size,
        "install should read config.database when no flag is given"
    end
  end

  def test_upgrade_falls_back_to_config_database
    Dir.mktmpdir do |dir|
      SagaForge.configure { |c| c.database = :billing }
      FileUtils.mkdir_p(File.join(dir, "db", "billing_migrate"))
      File.write(File.join(dir, "db", "billing_migrate", "20240101000000_install_saga_forge.rb"), "# existing\n")

      run_generator(SagaForge::UpgradeGenerator, dir)

      names = Dir.glob(File.join(dir, "db", "billing_migrate", "*.rb"))
        .map { |f| File.basename(f).sub(/\A\d+_/, "") }
      assert_equal 1, names.count("install_saga_forge.rb"),
        "upgrade must not re-copy the existing install migration"
    end
  end
end

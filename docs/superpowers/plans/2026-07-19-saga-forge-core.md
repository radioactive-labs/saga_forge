# SagaForge Core Gem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SagaForge core gem (phase 1) — a saga engine for Rails on ActiveJob with an event ledger, commit-at-end atomicity, stalling/parking, and LIFO compensation — per the approved spec.

**Architecture:** Plain gem (no engine) + zeitwerk, with a tiny opt-in Railtie for saga eager-loading. Two tables (`saga_forge_states`, `saga_forge_events`) behind an angarium-style `SagaForge::ApplicationRecord` with `connects_to` multi-DB routing. Event processing = one `ExecutionJob` per ledger row: lifecycle checks → run handler block in memory → single commit (row lock + version check) → enqueue staged rows → re-deliver parked events.

**Tech Stack:** Ruby >= 3.2, activerecord/activejob >= 7.1, zeitwerk. Tests: Minitest + Combustion + chaotic_job. Lint: standard. Reference codebases: `/Users/stefan/Documents/plutonium/chrono_forge` (retry policies, test harness, tooling), `/Users/stefan/Documents/radioactive_labs/angarium` (multi-DB generators).

**User Verification:** NO — no user verification required. (Spec approval already happened; verification is automated tests.)

**Spec:** `docs/superpowers/specs/2026-07-19-saga-forge-design.md` (Appendix A = semantic contract, cited as §A.x below).

**Commit policy note:** Stefan's global rule is "never stage or commit unless explicitly asked." Approving execution of this plan is that explicit ask for the commits listed in commit steps — commit exactly what each task's commit step names, nothing more.

**Implementation decisions locked here (consistent across all tasks):**
- Event statuses: integer enum `{pending: 0, processed: 1, stalled: 2, failed: 3}`.
- `event_id` uniqueness is the compound `[event_id, saga_class]` (deviation from spec's bare unique `event_id`: one broadcast publish creates one row per recipient class sharing the producer's `event_id`; dedup semantics are per-recipient).
- Correlation ids are stored as strings (`to_s` at resolution).
- `Definition::START = :__start__` is the registered "state" of the start event; a saga with no row is at `START`.
- Rollback in-flight uses internal state `:compensating` (an honest position; terminal is `:compensated`/`:cancelled`). Engine bookkeeping lives in `context["__saga_forge"]` (keys: `"failure_reason"`, `"target"`, `"compensated"` array, `"comp_attempts"` hash, `"comp_error"`).
- Facade outcome values: `nil` (fall through), `:stay`, `[:transition_to, sym]`, `[:fail, reason]`. `fail!` throws `:saga_forge_fail` to halt the block.
- Runner→job outcomes: `[:done]`, `[:respin]` (stall spin, no budget), `[:retry, seconds]` (policy backoff or transient conflict).
- Version-conflict / duplicate-row races raise internal `SagaForge::ConcurrencyConflict`, retried without touching retry budgets.
- Staged publish `event_id`s are deterministic: `"staged:#{source_event_id}:#{seq}"` (forward blocks), `"staged:comp:#{state_id}:#{comp_name}:#{seq}"` (compensations); `saga_class` disambiguates recipients under the compound index.
- Compensation failure after exhausting the tolerant policy: recorded in `context["__saga_forge"]["comp_error"]`, logged with `Rails.logger.error { }`, saga stays `:compensating`; operator re-runs `compensate!` after fixing (spec leaves this surface open — see §A.4 sharp edge).
- `stay` inside `start_with` raises `SagaForge::Error` (there is no start state to remain in).
- **HashWithIndifferentAccess aliasing (discovered in Task 6):** `(context["__saga_forge"] ||= {})` is a BUG against HWIA — `[]=` stores a converted copy, but the `||=` expression evaluates to the original literal, so mutations through the alias never reach `context`. Everywhere the plan's snippets (Tasks 8, 9, 11) mutate `context["__saga_forge"]`, use read-merge-reassign instead: `meta = (context["__saga_forge"] || {}).merge(...); context["__saga_forge"] = meta`.

---

## File Structure

```
saga_forge/
├── saga_forge.gemspec
├── Gemfile
├── Rakefile
├── .standard.yml
├── .gitignore
├── README.md
├── db/saga_forge_migrate/
│   └── 20260719000001_create_saga_forge_tables.rb
├── lib/
│   ├── saga_forge.rb                       # zeitwerk, errors, config accessors, publish, guard flag
│   ├── saga_forge/
│   │   ├── version.rb
│   │   ├── configuration.rb                # §A.6 + database/connects_to/primary_key_type
│   │   ├── application_record.rb           # angarium connects_to pattern
│   │   ├── state.rb                        # saga_forge_states model + operator API
│   │   ├── event.rb                        # saga_forge_events model (the ledger)
│   │   ├── retry_policy.rb                 # ported from chrono_forge
│   │   ├── composite_retry_policy.rb       # ported from chrono_forge
│   │   ├── base.rb                         # DSL macros + class-level introspection
│   │   ├── definition.rb                   # compiled chain, validations, mermaid
│   │   ├── router.rb                       # event → saga classes registry + row builder
│   │   ├── publisher.rb                    # external SagaForge.publish
│   │   ├── railtie.rb                      # eager-load app/sagas (required conditionally)
│   │   ├── execution/
│   │   │   ├── facade.rb                   # the `saga` object yielded to forward blocks
│   │   │   ├── compensation_facade.rb      # the `saga` object yielded to compensations
│   │   │   └── runner.rb                   # lifecycle checks + block run + commit
│   │   ├── execution_job.rb
│   │   ├── compensation_runner.rb
│   │   ├── compensation_job.rb
│   │   ├── timeout_job.rb
│   │   ├── sweeper_job.rb
│   │   └── retention_job.rb
│   └── generators/saga_forge/
│       ├── install/install_generator.rb
│       ├── install/templates/initializer.rb
│       ├── install/USAGE
│       ├── migrations/migrations_generator.rb
│       └── migrations/USAGE
└── test/
    ├── test_helper.rb
    ├── internal/                            # Combustion app
    │   ├── config/database.yml
    │   ├── config/routes.rb
    │   ├── db/schema.rb
    │   ├── db/migrate/20260719000001_create_saga_forge_tables.rb  (copy)
    │   └── app/sagas/…                      # fixture sagas per task
    └── *_test.rb
```

---

### Task 0: Repo scaffold, configuration, and test harness

**Goal:** A bootable gem skeleton where `bundle exec rake test` runs a passing smoke test against a Combustion app.

**Files:**
- Create: `saga_forge.gemspec`, `Gemfile`, `Rakefile`, `.standard.yml`, `.gitignore`
- Create: `lib/saga_forge.rb`, `lib/saga_forge/version.rb`, `lib/saga_forge/configuration.rb`
- Create: `test/test_helper.rb`, `test/internal/config/database.yml`, `test/internal/config/routes.rb`, `test/internal/db/schema.rb`
- Test: `test/configuration_test.rb`

**Acceptance Criteria:**
- [ ] `bundle install` succeeds; `bundle exec rake test` green; `bundle exec standardrb` clean
- [ ] `SagaForge.config` defaults match §A.6 plus `database`/`connects_to`/`primary_key_type` nil defaults
- [ ] `SagaForge.configure` + `reset_configuration!` work; `migrations_database` resolves database → connects_to writing role → nil

**Verify:** `bundle exec rake test` → all green.

**Steps:**

- [ ] **Step 1: Scaffold gem files**

`saga_forge.gemspec`:
```ruby
require_relative "lib/saga_forge/version"

Gem::Specification.new do |spec|
  spec.name = "saga_forge"
  spec.version = SagaForge::VERSION
  spec.authors = ["Stefan Froelich"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.summary = "Sagas for Rails on ActiveJob: one file, one ledger, commit-at-end atomicity, LIFO compensation."
  spec.description = "MassTransit's state machine, ChronoForge's spirit. Event-driven sagas with durable event ledger, stalling/parking, staged publishes, and derived compensation."
  spec.homepage = "https://github.com/radioactive-labs/saga_forge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == File.basename(__FILE__)) ||
        f.start_with?("bin/", "test/", "spec/", "features/", ".git", ".github", "appraisal", "gemfiles/", "docs/", "site/", "saga_forge-dashboard/")
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "zeitwerk"
end
```

`Gemfile`:
```ruby
source "https://rubygems.org"
gemspec

gem "rake"
gem "minitest"
gem "minitest-reporters"
gem "combustion"
gem "chaotic_job"
gem "rails", ">= 7.1"
gem "sqlite3"
gem "standard"
gem "appraisal"
```

`Rakefile`:
```ruby
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "standard/rake"

task default: %i[test standard]

# Neutralize bundler's `rake release` footgun (release flow comes with the
# dashboard-phase tooling; until then, releases are manual and deliberate).
Rake::Task["release"].clear if Rake::Task.task_defined?("release")
```

`.standard.yml`:
```yaml
ruby_version: 3.2
ignore:
  - "test/internal/**/*"
```

`.gitignore`:
```
/.bundle/
/tmp/
/pkg/
Gemfile.lock
gemfiles/*.lock
test/internal/db/*.sqlite3*
test/internal/log/
```

- [ ] **Step 2: Core lib files**

`lib/saga_forge/version.rb`:
```ruby
module SagaForge
  VERSION = "0.1.0"
end
```

`lib/saga_forge/configuration.rb`:
```ruby
module SagaForge
  class Configuration
    attr_accessor :stall_wait, :stall_budget, :sweep_interval, :retention,
      :job_queue, :database, :connects_to, :primary_key_type

    def initialize
      @stall_wait = 3.seconds
      @stall_budget = 40
      @sweep_interval = 30.seconds
      @retention = 90.days
      @job_queue = :sagas
      @database = nil
      @connects_to = nil
      @primary_key_type = nil
    end

    # Which named database the generators should target when no --database
    # flag is given: explicit database name, else the connects_to writing role.
    def migrations_database
      database || connects_to&.dig(:database, :writing)
    end
  end
end
```

`lib/saga_forge.rb`:
```ruby
# frozen_string_literal: true

require "zeitwerk"
require "active_record"
require "active_job"
require "digest"

module SagaForge
  Loader = Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/generators")
    loader.ignore("#{__dir__}/saga_forge/railtie.rb")
    loader.setup
  end

  class Error < StandardError; end

  # Boot-time definition errors (§A.8)
  class AmbiguousEventError < Error; end
  class UnknownCompensationError < Error; end
  class MissingCorrelationError < Error; end
  class NoTerminalStateError < Error; end
  class DefinitionError < Error; end

  # Runtime errors
  class UnknownStateError < Error; end
  class UnstagedPublishError < Error; end
  class ConcurrencyConflict < Error; end # internal: version race / duplicate create

  class << self
    def config = @config ||= Configuration.new

    def configure = yield(config)

    def reset_configuration! = @config = Configuration.new

    # External publish entry point (§A.2). Raises UnstagedPublishError inside
    # saga execution — use saga.publish there.
    def publish(event_name, event_id: nil, **payload)
      Publisher.publish(event_name, event_id: event_id, payload: payload)
    end

    # PK type for engine tables: explicit config → host generator config → Rails default.
    def primary_key_type
      config.primary_key_type ||
        (defined?(Rails.application) && Rails.application &&
          Rails.application.config.generators.options.dig(:active_record, :primary_key_type)) ||
        :primary_key
    end

    # --- execution guard (§A.2 guard mechanics) ---

    def within_saga_execution?
      !!ActiveSupport::IsolatedExecutionState[:saga_forge_execution]
    end

    # Wrapped around user block invocation ONLY (forward, compensation, timeout
    # handling). Footgun-catcher, not a sandbox.
    def guarding_execution
      previous = ActiveSupport::IsolatedExecutionState[:saga_forge_execution]
      ActiveSupport::IsolatedExecutionState[:saga_forge_execution] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:saga_forge_execution] = previous
    end
  end
end

require "saga_forge/railtie" if defined?(Rails::Railtie)
```

(`lib/saga_forge/railtie.rb` is created in Task 4; until then the conditional require is inert in the pure-gem test harness because Combustion defines `Rails::Railtie` *before* `require "saga_forge"` — so create a stub now to keep Task 0 green:)

`lib/saga_forge/railtie.rb` (stub, completed in Task 4):
```ruby
module SagaForge
  class Railtie < Rails::Railtie
  end
end
```

- [ ] **Step 3: Test harness**

`test/internal/config/database.yml`:
```yaml
test:
  adapter: sqlite3
  database: db/test.sqlite3
  pool: 20
```

`test/internal/config/routes.rb`:
```ruby
Rails.application.routes.draw {}
```

`test/internal/db/schema.rb`:
```ruby
ActiveRecord::Schema.define do
  # Host-app tables for fixtures would go here. Engine tables come from
  # test/internal/db/migrate (Task 1).
end
```

`test/test_helper.rb`:
```ruby
# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]

require "combustion"
Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job do
  config.active_job.queue_adapter = :test
end

require "saga_forge"
require "rails/test_help"

module SagaForge
  class TestCase < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      SagaForge.reset_configuration!
    end
  end
end
```

Note: `require "saga_forge"` comes AFTER Combustion so `defined?(Rails::Railtie)` is true and the railtie loads, matching production load order (gem required by bundler after rails). Combustion requires the gem itself via Bundler.require — to control ordering, the `Gemfile` entry for the gem is implicit through `gemspec`; if Bundler.require loads saga_forge before Combustion initializes, that is also fine (Rails::Railtie is defined by `combustion`'s rails require). Keep both paths working: the railtie only hooks `to_prepare`.

- [ ] **Step 4: Configuration test**

`test/configuration_test.rb`:
```ruby
require "test_helper"

class ConfigurationTest < SagaForge::TestCase
  test "defaults" do
    c = SagaForge::Configuration.new
    assert_equal 3.seconds, c.stall_wait
    assert_equal 40, c.stall_budget
    assert_equal 30.seconds, c.sweep_interval
    assert_equal 90.days, c.retention
    assert_equal :sagas, c.job_queue
    assert_nil c.database
    assert_nil c.connects_to
    assert_nil c.primary_key_type
  end

  test "configure and reset" do
    SagaForge.configure { |c| c.stall_budget = 5 }
    assert_equal 5, SagaForge.config.stall_budget
    SagaForge.reset_configuration!
    assert_equal 40, SagaForge.config.stall_budget
  end

  test "migrations_database resolution order" do
    c = SagaForge::Configuration.new
    assert_nil c.migrations_database
    c.connects_to = {database: {writing: :saga, reading: :saga}}
    assert_equal :saga, c.migrations_database
    c.database = :billing
    assert_equal :billing, c.migrations_database
  end

  test "guard flag" do
    refute SagaForge.within_saga_execution?
    SagaForge.guarding_execution do
      assert SagaForge.within_saga_execution?
    end
    refute SagaForge.within_saga_execution?
  end
end
```

- [ ] **Step 5: Run and commit**

Run: `cd /Users/stefan/Documents/plutonium/saga_forge && bundle install && bundle exec rake` → tests green, standard clean.

```bash
git add -A
git commit -m "feat: gem scaffold, configuration, combustion test harness"
```

```json:metadata
{"files": ["saga_forge.gemspec", "lib/saga_forge.rb", "lib/saga_forge/configuration.rb", "test/test_helper.rb"], "verifyCommand": "bundle exec rake", "acceptanceCriteria": ["rake test green", "config defaults per spec", "migrations_database resolution"], "requiresUserVerification": false}
```

---

### Task 1: Schema migration, ApplicationRecord, State and Event models

**Goal:** The two tables (§A.9), the angarium-style connection-routing base class, and models with enums/scopes/associations.

**Files:**
- Create: `db/saga_forge_migrate/20260719000001_create_saga_forge_tables.rb`
- Create: `test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb` (identical copy so Combustion migrates it)
- Create: `lib/saga_forge/application_record.rb`, `lib/saga_forge/state.rb`, `lib/saga_forge/event.rb`
- Test: `test/schema_test.rb`, `test/models_test.rb`

**Acceptance Criteria:**
- [ ] Both tables exist with all §A.9 columns and inline indexes (compound `[event_id, saga_class]` unique)
- [ ] `Event` enum works; `State#events`, `State#history` ordered by ledger insertion
- [ ] `State.stalled` / `State.suspended` derived scopes work (IN-subquery on the ledger)
- [ ] `ApplicationRecord` calls no `connects_to` when config is empty (models on primary connection)

**Steps:**

- [ ] **Step 1: Migration** (inline indexes/constraints in `create_table` — house rule)

`db/saga_forge_migrate/20260719000001_create_saga_forge_tables.rb`:
```ruby
# This migration ships with saga_forge. Engine tables live wherever
# SagaForge::ApplicationRecord connects (primary DB by default).
class CreateSagaForgeTables < ActiveRecord::Migration[7.1]
  def change
    fk_type = SagaForge.primary_key_type
    fk_type = :bigint if fk_type == :primary_key

    create_table :saga_forge_states, id: SagaForge.primary_key_type do |t|
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      t.string :current_state, null: false
      t.integer :version, null: false, default: 0
      if t.respond_to?(:jsonb)
        t.jsonb :context, null: false, default: {}
      else
        t.json :context
      end
      t.timestamps

      t.index %i[saga_class correlation_id], unique: true
      t.index %i[saga_class current_state]
    end

    create_table :saga_forge_events, id: SagaForge.primary_key_type do |t|
      t.string :event_id, null: false
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      t.references :saga_forge_state, type: fk_type, foreign_key: {to_table: :saga_forge_states}, index: false
      t.string :event_name, null: false
      t.integer :status, null: false, default: 0
      t.integer :stall_count, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      if t.respond_to?(:jsonb)
        t.jsonb :payload, null: false, default: {}
        t.jsonb :retry_budgets, null: false, default: {}
        t.jsonb :error
      else
        t.json :payload
        t.json :retry_budgets
        t.json :error
      end
      t.timestamps

      t.index %i[event_id saga_class], unique: true
      t.index %i[saga_class correlation_id status]
      t.index %i[status created_at]
      t.index %i[saga_forge_state_id created_at]
    end
  end
end
```

Copy the same file to `test/internal/db/migrate/` (Combustion runs it at boot).

- [ ] **Step 2: ApplicationRecord (angarium pattern)**

`lib/saga_forge/application_record.rb`:
```ruby
module SagaForge
  # All engine models subclass this abstract class, so pointing it at a
  # connection moves the whole engine. Config is read once at class load —
  # safe because initializers run before models are first referenced.
  # Nothing configured → models stay on the app's primary connection.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    if SagaForge.config.connects_to
      connects_to(**SagaForge.config.connects_to)
    elsif (db = SagaForge.config.database)
      connects_to database: {writing: db, reading: db}
    end
  end
end
```

- [ ] **Step 3: Models**

`lib/saga_forge/event.rb`:
```ruby
module SagaForge
  # The ledger (§A.9): inbound rows only, append-only, mutable status.
  class Event < ApplicationRecord
    self.table_name = "saga_forge_events"

    belongs_to :state, class_name: "SagaForge::State",
      foreign_key: :saga_forge_state_id, optional: true

    enum :status, {pending: 0, processed: 1, stalled: 2, failed: 3}

    scope :for_instance, ->(saga_class, correlation_id) {
      where(saga_class: saga_class.to_s, correlation_id: correlation_id.to_s)
    }
    scope :ledger_order, -> { order(:created_at, :id) }
  end
end
```

`lib/saga_forge/state.rb` (operator methods land in Task 11 — start with the data surface):
```ruby
module SagaForge
  # The saga's ground truth, and only the truth (§A.9). current_state is
  # always the real workflow position; stalls/failures live on Event rows.
  class State < ApplicationRecord
    self.table_name = "saga_forge_states"

    COMPENSATING = :compensating
    COMPENSATED = :compensated
    CANCELLED = :cancelled

    has_many :events, class_name: "SagaForge::Event",
      foreign_key: :saga_forge_state_id, dependent: nil

    scope :for_saga, ->(klass) { where(saga_class: klass.to_s) }
    scope :in_state, ->(state) { where(current_state: state.to_s) }
    scope :stalled, -> { where(id: Event.stalled.select(:saga_forge_state_id)) }
    scope :suspended, -> { where(id: Event.failed.select(:saga_forge_state_id)) }

    def history = events.ledger_order

    def saga_definition = saga_class.constantize.definition
  end
end
```

- [ ] **Step 4: Tests**

`test/schema_test.rb`:
```ruby
require "test_helper"

class SchemaTest < SagaForge::TestCase
  test "tables and key indexes exist" do
    conn = SagaForge::ApplicationRecord.connection
    assert conn.table_exists?(:saga_forge_states)
    assert conn.table_exists?(:saga_forge_events)
    assert conn.index_exists?(:saga_forge_states, %i[saga_class correlation_id], unique: true)
    assert conn.index_exists?(:saga_forge_events, %i[event_id saga_class], unique: true)
    assert conn.index_exists?(:saga_forge_events, %i[saga_class correlation_id status])
    assert conn.index_exists?(:saga_forge_events, %i[status created_at])
  end
end
```

`test/models_test.rb`:
```ruby
require "test_helper"

class ModelsTest < SagaForge::TestCase
  def build_state(corr: "1", state: "waiting")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: corr, current_state: state)
  end

  test "event enum and dedup index" do
    s = build_state
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "went", payload: {a: 1}, state: s)
    assert_raises(ActiveRecord::RecordNotUnique) do
      SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "1",
        event_name: "went", payload: {a: 1})
    end
    # same event_id for a DIFFERENT saga_class is allowed (broadcast fan-out)
    SagaForge::Event.create!(event_id: "e1", saga_class: "OtherSaga", correlation_id: "1",
      event_name: "went", payload: {a: 1})
  end

  test "derived stalled and suspended scopes" do
    healthy = build_state(corr: "1")
    stalled = build_state(corr: "2")
    suspended = build_state(corr: "3")
    SagaForge::Event.create!(event_id: "s1", saga_class: "DemoSaga", correlation_id: "2",
      event_name: "early", status: :stalled, state: stalled)
    SagaForge::Event.create!(event_id: "f1", saga_class: "DemoSaga", correlation_id: "3",
      event_name: "boom", status: :failed, state: suspended)

    assert_equal [stalled.id], SagaForge::State.stalled.ids
    assert_equal [suspended.id], SagaForge::State.suspended.ids
    refute_includes SagaForge::State.stalled.ids, healthy.id
  end

  test "history is ledger ordered" do
    s = build_state
    e1 = SagaForge::Event.create!(event_id: "a", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "one", state: s, created_at: 2.minutes.ago)
    e2 = SagaForge::Event.create!(event_id: "b", saga_class: "DemoSaga", correlation_id: "1",
      event_name: "two", state: s, created_at: 1.minute.ago)
    assert_equal [e1.id, e2.id], s.history.ids
  end
end
```

- [ ] **Step 5: Run and commit**

Run: `bundle exec rake` → green.

```bash
git add -A
git commit -m "feat: schema, ApplicationRecord multi-DB routing, State and Event models"
```

```json:metadata
{"files": ["db/saga_forge_migrate/20260719000001_create_saga_forge_tables.rb", "lib/saga_forge/application_record.rb", "lib/saga_forge/state.rb", "lib/saga_forge/event.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["tables + indexes per §A.9", "enums/scopes/associations", "no connects_to when unconfigured"], "requiresUserVerification": false}
```

---

### Task 2: Retry policies (port from chrono_forge)

**Goal:** `RetryPolicy` and `CompositeRetryPolicy` value objects with saga-flavored defaults.

**Files:**
- Create: `lib/saga_forge/retry_policy.rb`, `lib/saga_forge/composite_retry_policy.rb`
- Source: `/Users/stefan/Documents/plutonium/chrono_forge/lib/chrono_forge/executor/retry_policy.rb` and `composite_retry_policy.rb`
- Test: `test/retry_policy_test.rb` (adapt cases from chrono_forge's `test/retry_policy_test.rb` + `test/composite_retry_policy_test.rb`)

**Acceptance Criteria:**
- [ ] Identical semantics to chrono_forge: `retryable?`, `backoff_for` (equal jitter, `min(cap, base×2^(n−1))`), `matches?`, `budget_key`, `retry_backoff` (block form supplies per-budget counts), composite routing with per-declared-error budgets, `max_attempts` coarsest bound
- [ ] Saga defaults: `RetryPolicy.step_default` = 3 attempts / cap 30 / any error; `RetryPolicy.compensation_default` = 10 attempts / cap 600 / any error (§A.5)

**Steps:**

- [ ] **Step 1: Port both files.** Copy the chrono_forge sources verbatim, then apply exactly these changes:
  - Namespace `ChronoForge::Executor` → `SagaForge` (top-level classes, files at `lib/saga_forge/retry_policy.rb` / `lib/saga_forge/composite_retry_policy.rb`).
  - Rename `workflow_default` → `compensation_default` (same numbers: `max_attempts: 10, base: 1, cap: 600, jitter: true, retry_on: nil`); update its comment to say compensations get the tolerant policy because giving up mid-rollback is worse (§A.5).
  - Delete `wait_default` (no wait primitive in SagaForge).
  - Keep `self.compose`, referencing `SagaForge::CompositeRetryPolicy`.

- [ ] **Step 2: Tests.** Port chrono_forge's retry policy unit tests (value-object tests only — not the executor integration ones), adjusting namespaces. Minimum coverage:

```ruby
require "test_helper"

class RetryPolicyTest < SagaForge::TestCase
  test "backoff is capped exponential with equal jitter bounds" do
    p = SagaForge::RetryPolicy.new(base: 2, cap: 60, jitter: true)
    d = p.backoff_for(3) # raw = min(60, 2*2^2) = 8
    assert_includes 4.0..8.0, d.to_f
  end

  test "retry_on list matches subclasses; [] retries nothing; nil any StandardError" do
    io = SagaForge::RetryPolicy.new(retry_on: [IOError])
    assert io.matches?(EOFError.new)   # subclass
    refute io.matches?(ArgumentError.new)
    none = SagaForge::RetryPolicy.new(retry_on: [])
    refute none.matches?(StandardError.new)
  end

  test "budget_key stable under reordering" do
    p = SagaForge::RetryPolicy.new(retry_on: [IOError, ArgumentError])
    assert_equal "ArgumentError,IOError", p.budget_key
    assert_equal "*", SagaForge::RetryPolicy.new.budget_key
  end

  test "composite routes first match, unmatched errors fail fast" do
    composite = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(retry_on: [IOError], max_attempts: 5),
      SagaForge::RetryPolicy.new(retry_on: [ArgumentError], max_attempts: 1)
    ])
    assert composite.retry_backoff(IOError.new, attempts: 1)
    assert_nil composite.retry_backoff(ArgumentError.new, attempts: 1) # 1 attempt made = budget spent
    assert_nil composite.retry_backoff(RuntimeError.new, attempts: 0)  # unmatched
  end

  test "composite block form supplies per-budget count" do
    composite = SagaForge::CompositeRetryPolicy.new([
      SagaForge::RetryPolicy.new(retry_on: [IOError], max_attempts: 2)
    ])
    result = composite.retry_backoff(IOError.new, attempts: 99) { |budget_key| 1 }
    assert result
  end

  test "saga defaults" do
    assert_equal 3, SagaForge::RetryPolicy.step_default.max_attempts
    assert_equal 10, SagaForge::RetryPolicy.compensation_default.max_attempts
    assert_equal 600, SagaForge::RetryPolicy.compensation_default.cap
  end
end
```

- [ ] **Step 3: Run and commit**

Run: `bundle exec rake` → green.

```bash
git add lib/saga_forge/retry_policy.rb lib/saga_forge/composite_retry_policy.rb test/retry_policy_test.rb
git commit -m "feat: port RetryPolicy and CompositeRetryPolicy from chrono_forge"
```

```json:metadata
{"files": ["lib/saga_forge/retry_policy.rb", "lib/saga_forge/composite_retry_policy.rb"], "verifyCommand": "bundle exec rake test TEST=test/retry_policy_test.rb", "acceptanceCriteria": ["chrono semantics preserved", "step_default + compensation_default"], "requiresUserVerification": false}
```

---

### Task 3: DSL (`SagaForge::Base`) and compiled `Definition`

**Goal:** The class macros record declarations; `Definition.compile` builds the chain, event→state map, handler registry, compensation catalog; boot validations (§A.8); `to_mermaid`.

**Files:**
- Create: `lib/saga_forge/base.rb`, `lib/saga_forge/definition.rb`
- Create: `test/internal/app/sagas/order_saga.rb` (canonical fixture, used by later tasks too)
- Test: `test/definition_test.rb`

**Acceptance Criteria:**
- [ ] Chain built from file order: start → first during state → next distinct during state → … → first finish (§A.1)
- [ ] All handlers of a state share the successor; `state_for_event` maps start event → `Definition::START`
- [ ] Boot validations raise: `AmbiguousEventError`, `UnknownCompensationError`, `MissingCorrelationError` (no `correlate_by`), `NoTerminalStateError`, `DefinitionError` (no/duplicate `start_with`)
- [ ] `correlate` uses symbol sugar or block (payload, event_name), `to_s`'d; nil → `MissingCorrelationError` naming the class
- [ ] Retry policy resolution: handler override (policy / array / kwargs-hash) → class default → nil
- [ ] `to_mermaid` renders solid chain edges labeled by event, dashed best-effort `transition_to` jumps, terminals

**Steps:**

- [ ] **Step 1: Fixture saga**

`test/internal/app/sagas/order_saga.rb`:
```ruby
class OrderSaga < SagaForge::Base
  correlate_by :order_id

  start_with :order_placed, compensate: :refund do |saga, payload|
    saga.context[:total] = payload[:total]
    saga.context[:charges] = (saga.context[:charges] || []) << "ch_#{saga.correlation_id}"
  end

  during :awaiting_settlement, on: :payment_settled, compensate: :release_stock do |saga, _payload|
    saga.context[:reserved] = true
    saga.publish :order_fulfilled, order_id: saga.correlation_id
  end

  during :awaiting_settlement, on: :payment_failed do |saga, payload|
    saga.fail! reason: payload[:code]
  end

  during :awaiting_review, on: :review_passed do |saga, _payload|
    saga.transition_to :completed if saga.context[:total].to_i > 0
  end

  finish_with :completed

  compensation :refund do |saga|
    next unless saga.context[:charges]
    saga.context[:refunded] = saga.context[:charges].dup
  end

  compensation :release_stock do |saga|
    saga.context[:released] = true
  end
end
```

- [ ] **Step 2: `Base`**

`lib/saga_forge/base.rb`:
```ruby
module SagaForge
  # The saga DSL. Macros only record; Definition.compile (lazy, memoized)
  # builds and validates the machine. The file IS the state machine (§A.1).
  class Base
    class << self
      attr_reader :correlator, :default_retry_policy

      def inherited(subclass)
        super
        Router.register(subclass)
      end

      def correlate_by(key = nil, &block)
        @correlator = block || ->(payload, _event = nil) { payload[key] }
      end

      def start_with(event, compensate: nil, timeout: nil, on_timeout: nil, retry_policy: nil, &block)
        declarations << {kind: :start, event: event.to_sym, compensate:, timeout:, on_timeout:, retry_policy:, block:}
      end

      def during(state, on:, compensate: nil, timeout: nil, on_timeout: nil, retry_policy: nil, &block)
        declarations << {kind: :during, state: state.to_sym, event: on.to_sym, compensate:, timeout:, on_timeout:, retry_policy:, block:}
      end

      def finish_with(state)
        declarations << {kind: :finish, state: state.to_sym}
      end

      def compensation(name, &block)
        declarations << {kind: :compensation, name: name.to_sym, block:}
      end

      def retry_policy(*policies, **kwargs)
        @default_retry_policy =
          if policies.any?
            (policies.size == 1 && !kwargs.any?) ? policies.first : CompositeRetryPolicy.new(policies)
          else
            RetryPolicy.new(**kwargs)
          end
      end

      def declarations = @declarations ||= []

      def definition = @definition ||= Definition.compile(self)

      # Introspection & recovery (§A.7) — instance-level ops land in Task 11.
      def find_by_correlation(correlation_id) = State.for_saga(self).find_by(correlation_id: correlation_id.to_s)

      def in_state(state) = State.for_saga(self).in_state(state)

      def stalled = State.for_saga(self).stalled

      def suspended = State.for_saga(self).suspended

      def to_mermaid = definition.to_mermaid
    end
  end
end
```

- [ ] **Step 3: `Definition`**

`lib/saga_forge/definition.rb`:
```ruby
module SagaForge
  # Immutable boot-compiled metadata for one saga class: the chain, the
  # event→state stall table, handler registry, compensation catalog.
  class Definition
    START = :__start__

    Handler = Struct.new(:state, :event, :block, :compensate, :timeout, :on_timeout, :retry_policy, keyword_init: true)

    attr_reader :klass, :handlers_by_event, :states, :terminal_states, :compensations, :start_event

    def self.compile(klass) = new(klass).freeze

    def initialize(klass)
      @klass = klass
      @handlers_by_event = {}
      @compensations = {}
      @terminal_states = []
      during_states = []
      start_decls = []

      klass.declarations.each do |d|
        case d[:kind]
        when :start
          start_decls << d
          register_handler(START, d)
        when :during
          during_states << d[:state] unless during_states.include?(d[:state])
          register_handler(d[:state], d)
        when :finish
          @terminal_states << d[:state] unless @terminal_states.include?(d[:state])
        when :compensation
          @compensations[d[:name]] = d[:block]
        end
      end

      validate_shape!(start_decls)
      @start_event = start_decls.first[:event]
      @states = during_states + @terminal_states
      @successors = build_successors(during_states)
      validate_compensations!
    end

    def handler_for(event) = @handlers_by_event[event.to_sym]

    def state_for_event(event) = handler_for(event)&.state

    def events = @handlers_by_event.keys

    def events_for_state(state) = @handlers_by_event.values.select { |h| h.state == state.to_sym }.map(&:event)

    def successor_of(state) = @successors.fetch(state.to_sym)

    def terminal?(state)
      s = state.to_sym
      @terminal_states.include?(s) || %i[compensated cancelled].include?(s)
    end

    def declared?(state)
      s = state.to_sym
      @states.include?(s) || terminal?(s)
    end

    def correlate(payload, event_name)
      correlator = klass.correlator
      value = (correlator.arity == 1) ? correlator.call(payload) : correlator.call(payload, event_name)
      if value.nil?
        raise MissingCorrelationError, "#{klass} registered #{event_name.inspect} but correlate_by returned nil"
      end
      value.to_s
    end

    # handler override → class default → step_default (compensations use
    # compensation_default; see CompensationRunner).
    def retry_policy_for(handler)
      override = handler.retry_policy
      policy =
        case override
        when nil then nil
        when Hash then RetryPolicy.new(**override)
        when Array then CompositeRetryPolicy.new(override)
        else override
        end
      policy || klass.default_retry_policy || RetryPolicy.step_default
    end

    def to_mermaid
      lines = ["stateDiagram-v2"]
      chain = [START] + @states.reject { |s| @terminal_states.include?(s) } + [@terminal_states.first]
      chain.each_cons(2) do |from, to|
        events_from = (from == START) ? [@start_event] : events_for_state(from)
        label = events_from.join(" / ")
        from_name = (from == START) ? "[*]" : from
        lines << "    #{from_name} --> #{to}: #{label}"
      end
      @terminal_states.each { |t| lines << "    #{t} --> [*]" }
      jump_targets.each { |(from, to)| lines << "    #{from} --> #{to}: jump" }
      lines.join("\n")
    end

    # Best-effort literal scan for `transition_to :sym` in handler blocks
    # (§A.8 — jumps are opaque; unresolvable ones are simply not drawn).
    def jump_targets
      handlers = @handlers_by_event.values.sort_by { |h| h.block.source_location&.last || 0 }
      by_file = handlers.group_by { |h| h.block.source_location&.first }.compact
      jumps = []
      by_file.each do |file, hs|
        next unless file && File.exist?(file)
        File.readlines(file).each_with_index do |line, idx|
          line.scan(/transition_to[\s(]+:(\w+)/) do |(target)|
            owner = hs.select { |h| h.block.source_location.last <= idx + 1 }.max_by { |h| h.block.source_location.last }
            next unless owner
            from = (owner.state == START) ? "[*]" : owner.state
            jumps << [from, target.to_sym] if declared?(target)
          end
        end
      end
      jumps.uniq
    end

    private

    def register_handler(state, d)
      event = d[:event]
      if (existing = @handlers_by_event[event])
        raise AmbiguousEventError,
          "#{klass} registers #{event.inspect} under both #{existing.state.inspect} and #{state.inspect}"
      end
      @handlers_by_event[event] = Handler.new(
        state:, event:, block: d[:block], compensate: d[:compensate],
        timeout: d[:timeout], on_timeout: d[:on_timeout], retry_policy: d[:retry_policy]
      )
    end

    def validate_shape!(start_decls)
      raise DefinitionError, "#{klass} needs exactly one start_with (found #{start_decls.size})" unless start_decls.size == 1
      raise NoTerminalStateError, "#{klass} declares no finish_with" if @terminal_states.empty?
      raise MissingCorrelationError, "#{klass} is missing correlate_by" if klass.correlator.nil?
    end

    def build_successors(during_states)
      chain = [START] + during_states + [@terminal_states.first]
      chain.each_cons(2).to_h
    end

    def validate_compensations!
      @handlers_by_event.each_value do |h|
        next if h.compensate.nil? || @compensations.key?(h.compensate)
        raise UnknownCompensationError,
          "#{klass} handler for #{h.event.inspect} compensates with undeclared #{h.compensate.inspect}"
      end
    end
  end
end
```

- [ ] **Step 4: Tests** — `test/definition_test.rb`. Define throwaway saga classes inline (use `Class.new(SagaForge::Base)` assigned to constants via `stub_const`-style helper or plain named classes in the test file):

```ruby
require "test_helper"

class DefinitionTest < SagaForge::TestCase
  test "chain built from file order" do
    d = OrderSaga.definition
    assert_equal :order_placed, d.start_event
    assert_equal :awaiting_settlement, d.successor_of(SagaForge::Definition::START)
    assert_equal :awaiting_review, d.successor_of(:awaiting_settlement)
    assert_equal :completed, d.successor_of(:awaiting_review)
    assert d.terminal?(:completed)
    assert d.terminal?(:compensated)
  end

  test "state_for_event and events_for_state" do
    d = OrderSaga.definition
    assert_equal SagaForge::Definition::START, d.state_for_event(:order_placed)
    assert_equal :awaiting_settlement, d.state_for_event(:payment_settled)
    assert_equal %i[payment_settled payment_failed], d.events_for_state(:awaiting_settlement)
  end

  test "ambiguous event raises" do
    err = assert_raises(SagaForge::AmbiguousEventError) do
      Class.new(SagaForge::Base) do
        def self.name = "AmbiguousSaga"
        correlate_by :id
        start_with(:go) { |_, _| }
        during(:a, on: :tick) { |_, _| }
        during(:b, on: :tick) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_match(/tick/, err.message)
  end

  test "unknown compensation raises" do
    assert_raises(SagaForge::UnknownCompensationError) do
      Class.new(SagaForge::Base) do
        def self.name = "BadCompSaga"
        correlate_by :id
        start_with(:go, compensate: :nope) { |_, _| }
        finish_with :done
      end.definition
    end
  end

  test "missing correlate_by and no terminal raise" do
    assert_raises(SagaForge::MissingCorrelationError) do
      Class.new(SagaForge::Base) do
        def self.name = "NoCorr"
        start_with(:go) { |_, _| }
        finish_with :done
      end.definition
    end
    assert_raises(SagaForge::NoTerminalStateError) do
      Class.new(SagaForge::Base) do
        def self.name = "NoFinish"
        correlate_by :id
        start_with(:go) { |_, _| }
      end.definition
    end
  end

  test "correlate: symbol sugar, block with event name, nil raises" do
    d = OrderSaga.definition
    assert_equal "42", d.correlate({"order_id" => 42}.with_indifferent_access, :order_placed)
    assert_raises(SagaForge::MissingCorrelationError) do
      d.correlate({}.with_indifferent_access, :order_placed)
    end

    block_saga = Class.new(SagaForge::Base) do
      def self.name = "BlockCorr"
      correlate_by { |p, event| (event == :special) ? p[:sid] : p[:id] }
      start_with(:special) { |_, _| }
      finish_with :done
    end
    assert_equal "s9", block_saga.definition.correlate({sid: "s9"}.with_indifferent_access, :special)
  end

  test "retry policy resolution ladder" do
    d = OrderSaga.definition
    h = d.handler_for(:payment_settled)
    assert_equal 3, d.retry_policy_for(h).max_attempts # site default

    with_override = Class.new(SagaForge::Base) do
      def self.name = "RetrySaga"
      correlate_by :id
      retry_policy max_attempts: 7
      start_with(:go, retry_policy: {max_attempts: 2}) { |_, _| }
      during(:w, on: :tick) { |_, _| }
      finish_with :done
    end
    dd = with_override.definition
    assert_equal 2, dd.retry_policy_for(dd.handler_for(:go)).max_attempts     # handler override
    assert_equal 7, dd.retry_policy_for(dd.handler_for(:tick)).max_attempts  # class default
  end

  test "to_mermaid draws chain and jump" do
    m = OrderSaga.to_mermaid
    assert_includes m, "stateDiagram-v2"
    assert_includes m, "[*] --> awaiting_settlement: order_placed"
    assert_includes m, "awaiting_settlement --> awaiting_review"
    assert_includes m, "completed --> [*]"
    assert_includes m, "awaiting_review --> completed: jump"
  end
end
```

Note: `Router.register` doesn't exist until Task 4 — in this task, add a no-op stub `lib/saga_forge/router.rb`:
```ruby
module SagaForge
  class Router
    def self.register(klass); end
  end
end
```

- [ ] **Step 5: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: saga DSL and compiled Definition with boot validations and mermaid"
```

```json:metadata
{"files": ["lib/saga_forge/base.rb", "lib/saga_forge/definition.rb", "lib/saga_forge/router.rb", "test/internal/app/sagas/order_saga.rb"], "verifyCommand": "bundle exec rake test TEST=test/definition_test.rb", "acceptanceCriteria": ["chain from file order", "boot validations §A.8", "correlate semantics", "retry ladder", "mermaid"], "requiresUserVerification": false}
```

---

### Task 4: Router, external Publisher, Railtie

**Goal:** `SagaForge.publish` persists one row per registered recipient inside any open transaction, enqueues after, dedups by `[event_id, saga_class]`, and raises `UnstagedPublishError` inside execution. Railtie eager-loads `app/sagas`.

**Files:**
- Modify: `lib/saga_forge/router.rb` (replace stub)
- Create: `lib/saga_forge/publisher.rb`
- Modify: `lib/saga_forge/railtie.rb` (replace stub)
- Test: `test/publisher_test.rb`

**Acceptance Criteria:**
- [ ] `Router.resolve` returns one row-attribute hash per registered class with `correlation_id` from each class's `correlate_by`; `MissingCorrelationError` → zero rows inserted (atomic)
- [ ] `SagaForge.publish` inserts rows `status: pending` then enqueues one `ExecutionJob` per row (job class referenced by name; actual job lands in Task 5 — create a minimal `ExecutionJob < ActiveJob::Base` placeholder here with `def perform(event_row_id); end`)
- [ ] Explicit `event_id` dedups (second publish inserts nothing, enqueues nothing); no `event_id` → deterministic digest of event name + deep-sorted payload
- [ ] `SagaForge.publish` inside `guarding_execution` raises `UnstagedPublishError`
- [ ] Zero registered recipients → no-op returning `[]`

**Steps:**

- [ ] **Step 1: Router**

`lib/saga_forge/router.rb`:
```ruby
module SagaForge
  # Boot-time event → saga-class registry + the shared row builder used by
  # both publish paths (§A.2). Registration happens in Base.inherited;
  # reset on code reload (railtie to_prepare).
  class Router
    @classes = []

    class << self
      def register(klass)
        @classes << klass unless @classes.include?(klass)
      end

      def reset! = @classes = []

      def saga_classes = @classes

      def recipients_for(event_name)
        event = event_name.to_sym
        @classes.select { |k| k.definition.handler_for(event) }
      end

      # One fully-built Event attribute hash per recipient class. Raises
      # MissingCorrelationError before anything is inserted — atomic publish.
      def resolve(event_name, payload)
        payload = payload.with_indifferent_access
        recipients_for(event_name).map do |klass|
          {
            saga_class: klass.name,
            correlation_id: klass.definition.correlate(payload, event_name.to_sym),
            event_name: event_name.to_s,
            payload: payload,
            status: :pending
          }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Publisher**

`lib/saga_forge/publisher.rb`:
```ruby
module SagaForge
  # The external entry point (§A.2): INSERTs join any open transaction on the
  # engine connection; enqueues happen right after in plain code. The pending
  # row is the obligation, the enqueue a hint, the sweeper the guarantee.
  class Publisher
    class << self
      def publish(event_name, event_id:, payload:)
        if SagaForge.within_saga_execution?
          raise UnstagedPublishError,
            "SagaForge.publish called inside saga execution — use saga.publish (staged, delivered on commit)"
        end

        attrs_list = Router.resolve(event_name, payload)
        return [] if attrs_list.empty?

        event_id ||= digest_id(event_name, payload)
        rows = attrs_list.filter_map { |attrs| insert_row(attrs.merge(event_id: event_id)) }
        rows.each { |row| ExecutionJob.perform_later(row.id) }
        rows
      end

      def digest_id(event_name, payload)
        "digest:#{event_name}:#{Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload)))}"
      end

      private

      def insert_row(attrs)
        Event.create!(attrs)
      rescue ActiveRecord::RecordNotUnique
        nil # duplicate delivery (webhook redelivery) — the unique index no-ops it
      end

      def deep_sort(obj)
        case obj
        when Hash then obj.map { |k, v| [k.to_s, deep_sort(v)] }.sort.to_h
        when Array then obj.map { |v| deep_sort(v) }
        else obj
        end
      end
    end
  end
end
```

Placeholder `lib/saga_forge/execution_job.rb`:
```ruby
module SagaForge
  class ExecutionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(event_row_id)
      # Task 5/6 implement the pipeline.
    end
  end
end
```

- [ ] **Step 3: Railtie**

`lib/saga_forge/railtie.rb` (replace stub):
```ruby
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
      end
    end
  end
end
```

In `test/test_helper.rb`, after Combustion init add:
```ruby
Rails.application.eager_load!
```

- [ ] **Step 4: Tests**

`test/publisher_test.rb` (fixture `ShipmentSaga` also registers `:order_placed` with a different correlation key — add to `test/internal/app/sagas/shipment_saga.rb`):
```ruby
class ShipmentSaga < SagaForge::Base
  correlate_by { |p, _event| p[:shipment_ref] }
  start_with(:order_placed) { |saga, _payload| }
  finish_with :shipped
end
```

```ruby
require "test_helper"

class PublisherTest < SagaForge::TestCase
  test "broadcast: one row per registered class with each class's correlation" do
    rows = SagaForge.publish(:order_placed, event_id: "op:1", order_id: 42, shipment_ref: "SHP-9", total: 5)
    assert_equal %w[OrderSaga ShipmentSaga], rows.map(&:saga_class).sort
    assert_equal "42", rows.find { |r| r.saga_class == "OrderSaga" }.correlation_id
    assert_equal "SHP-9", rows.find { |r| r.saga_class == "ShipmentSaga" }.correlation_id
    assert rows.all?(&:pending?)
    assert_enqueued_jobs 2, only: SagaForge::ExecutionJob
  end

  test "missing correlation fails whole publish atomically" do
    assert_raises(SagaForge::MissingCorrelationError) do
      SagaForge.publish(:order_placed, event_id: "op:2", order_id: 42) # no shipment_ref
    end
    assert_equal 0, SagaForge::Event.count
    assert_no_enqueued_jobs
  end

  test "event_id dedup no-ops duplicates" do
    SagaForge.publish(:review_passed, event_id: "rv:1", order_id: 1)
    assert_no_difference -> { SagaForge::Event.count } do
      SagaForge.publish(:review_passed, event_id: "rv:1", order_id: 1)
    end
  end

  test "digest fallback is deterministic and key-order independent" do
    a = SagaForge::Publisher.digest_id(:x, {b: 1, a: [1, 2]})
    b = SagaForge::Publisher.digest_id(:x, {a: [1, 2], b: 1})
    assert_equal a, b
  end

  test "publish inside execution raises UnstagedPublishError" do
    SagaForge.guarding_execution do
      assert_raises(SagaForge::UnstagedPublishError) do
        SagaForge.publish(:order_placed, order_id: 1, shipment_ref: "s")
      end
    end
  end

  test "no registered recipients is a no-op" do
    assert_equal [], SagaForge.publish(:nobody_cares, event_id: "n:1", foo: 1)
    assert_no_enqueued_jobs
  end
end
```

- [ ] **Step 5: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: router, external publisher with dedup and guard, saga eager-load railtie"
```

```json:metadata
{"files": ["lib/saga_forge/router.rb", "lib/saga_forge/publisher.rb", "lib/saga_forge/railtie.rb", "lib/saga_forge/execution_job.rb"], "verifyCommand": "bundle exec rake test TEST=test/publisher_test.rb", "acceptanceCriteria": ["broadcast resolution", "atomic MissingCorrelationError", "dedup", "guard raises", "railtie eager-loads"], "requiresUserVerification": false}
```

---

### Task 5: ExecutionJob lifecycle checks (not-found, processed-skip, halt, stall/park)

**Goal:** The §A.4 pipeline steps before block execution, plus §A.3 stalling/parking, in `Execution::Runner` driven by `ExecutionJob`.

**Files:**
- Modify: `lib/saga_forge/execution_job.rb`
- Create: `lib/saga_forge/execution/runner.rb`
- Test: `test/execution_lifecycle_test.rb`

**Acceptance Criteria:**
- [ ] Missing row → `retry_job(wait: 2.seconds)` up to 5 executions, then silent discard
- [ ] `processed`/`stalled`/`failed` row → immediate exit, no side effects
- [ ] Instance with any `failed` event → other events left `pending`, exit (halt derived from ledger at job entry)
- [ ] Early event (registered state ≠ current state, incl. orphan `during` events with no saga row and re-delivered start events) → respin with `stall_wait`, `stall_count` incremented, parked (`stalled`) once `stall_count >= stall_budget`; saga row untouched; retry budgets untouched
- [ ] Event for a terminal-state instance → marked `processed` with discard note in `error` json (`{"discarded" => "terminal state <s>"}`, logged, not an error)

**Steps:**

- [ ] **Step 1: ExecutionJob**

Replace `lib/saga_forge/execution_job.rb`:
```ruby
module SagaForge
  # One job per ledger row; the row id is the only argument (§A.4).
  class ExecutionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    NOT_FOUND_RETRIES = 5
    NOT_FOUND_WAIT = 2.seconds

    if defined?(SolidQueue)
      limits_concurrency key: ->(event_row_id) {
        event = Event.find_by(id: event_row_id)
        event ? "SagaLock:#{event.saga_class}:#{event.correlation_id}" : "SagaLock:none"
      }
    end

    def perform(event_row_id)
      event = Event.find_by(id: event_row_id)
      unless event
        # Pre-commit race from an external publish inside a caller's
        # transaction: brief bounded retry, then silent discard (§A.2).
        retry_job(wait: NOT_FOUND_WAIT) if executions < NOT_FOUND_RETRIES
        return
      end

      outcome, arg = Execution::Runner.new(event).call
      case outcome
      when :respin then retry_job(wait: SagaForge.config.stall_wait)
      when :retry then retry_job(wait: arg)
      end
    end
  end
end
```

- [ ] **Step 2: Runner (lifecycle half — `execute!` raises NotImplementedError until Task 6)**

`lib/saga_forge/execution/runner.rb`:
```ruby
module SagaForge
  module Execution
    # Processes one pending ledger row through the §A.4 pipeline.
    # Returns [:done] | [:respin] | [:retry, seconds].
    class Runner
      attr_reader :event

      def initialize(event)
        @event = event
      end

      def call
        return [:done] unless event.pending?
        return [:done] if halted?

        saga_class = event.saga_class.constantize
        definition = saga_class.definition
        state_row = State.find_by(saga_class: event.saga_class, correlation_id: event.correlation_id)
        current = state_row&.current_state&.to_sym || Definition::START

        return discard_terminal!(current) if definition.terminal?(current)

        expected = definition.state_for_event(event.event_name)
        return stall! if expected != current

        execute!(definition, state_row, current)
      end

      private

      # Poison-pill halt (§A.3): derived from the ledger at job entry.
      def halted?
        Event.failed.for_instance(event.saga_class, event.correlation_id).exists?
      end

      def stall!
        count = event.stall_count + 1
        if count >= SagaForge.config.stall_budget
          event.update!(status: :stalled, stall_count: count)
          [:done]
        else
          event.update!(stall_count: count)
          [:respin]
        end
      end

      def discard_terminal!(current)
        event.update!(status: :processed, error: {"discarded" => "terminal state #{current}"})
        Rails.logger.info { "[saga_forge] discarded #{event.event_name} for terminal #{event.saga_class}##{event.correlation_id}" }
        [:done]
      end

      def execute!(definition, state_row, current)
        raise NotImplementedError, "Task 6"
      end
    end
  end
end
```

- [ ] **Step 3: Tests**

`test/execution_lifecycle_test.rb`:
```ruby
require "test_helper"

class ExecutionLifecycleTest < SagaForge::TestCase
  def make_event(name: "payment_settled", corr: "1", status: :pending, **attrs)
    SagaForge::Event.create!(event_id: SecureRandom.uuid, saga_class: "OrderSaga",
      correlation_id: corr, event_name: name, status: status, payload: {}, **attrs)
  end

  def make_state(corr: "1", state: "awaiting_settlement")
    SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: corr, current_state: state)
  end

  test "missing row retries then discards silently" do
    assert_nothing_raised do
      SagaForge::ExecutionJob.perform_now("00000000-0000-0000-0000-000000000000")
    end
    # one retry enqueued on first execution
    assert_enqueued_jobs 1, only: SagaForge::ExecutionJob
  end

  test "processed row exits immediately" do
    make_state
    e = make_event(status: :processed)
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
  end

  test "halt: failed event blocks pending siblings, saga untouched" do
    s = make_state
    make_event(name: "payment_failed", status: :failed)
    pending = make_event(name: "payment_settled")
    assert_equal [:done], SagaForge::Execution::Runner.new(pending).call
    assert pending.reload.pending?
    assert_equal "awaiting_settlement", s.reload.current_state
  end

  test "early event spins then parks; budgets untouched" do
    SagaForge.configure { |c| c.stall_budget = 2 }
    make_state(state: "awaiting_review")           # saga has moved past settlement? No — ahead of event
    e = make_event(name: "payment_settled")        # registered for awaiting_settlement
    assert_equal [:respin], SagaForge::Execution::Runner.new(e).call
    assert_equal 1, e.reload.stall_count
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    assert e.reload.stalled?
    assert_equal 0, e.attempts
  end

  test "orphan during-event with no saga row parks; re-delivered start event parks" do
    SagaForge.configure { |c| c.stall_budget = 1 }
    orphan = make_event(name: "payment_settled", corr: "404")
    assert_equal [:done], SagaForge::Execution::Runner.new(orphan).call
    assert orphan.reload.stalled?

    make_state(corr: "2", state: "awaiting_settlement")
    dup_start = make_event(name: "order_placed", corr: "2")
    assert_equal [:done], SagaForge::Execution::Runner.new(dup_start).call
    assert dup_start.reload.stalled?
  end

  test "terminal instance discards with note" do
    make_state(state: "completed")
    e = make_event(name: "payment_settled")
    assert_equal [:done], SagaForge::Execution::Runner.new(e).call
    assert e.reload.processed?
    assert_equal "terminal state completed", e.error["discarded"]
  end
end
```

- [ ] **Step 4: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: execution lifecycle — not-found absorption, halt, stall spin and parking"
```

```json:metadata
{"files": ["lib/saga_forge/execution_job.rb", "lib/saga_forge/execution/runner.rb"], "verifyCommand": "bundle exec rake test TEST=test/execution_lifecycle_test.rb", "acceptanceCriteria": ["not-found retry/discard", "halt from ledger", "stall spin/park", "terminal discard"], "requiresUserVerification": false}
```

---

### Task 6: Facade, block execution, and the single commit

**Goal:** Run handler blocks in memory with the `saga` facade; commit state/context/event/staged-rows atomically with lock + version check; enqueue staged jobs; re-deliver parked events. Happy-path end-to-end.

**Files:**
- Create: `lib/saga_forge/execution/facade.rb`
- Modify: `lib/saga_forge/execution/runner.rb` (implement `execute!` and commit)
- Test: `test/execution_commit_test.rb`, `test/saga_flow_test.rb`

**Acceptance Criteria:**
- [ ] Fall-through advances to successor; `transition_to` jumps (undeclared → `UnknownStateError`, nothing committed); `stay` remains (version still bumps); `stay` in `start_with` raises
- [ ] Start event creates the saga row inside the commit; duplicate-create race → `ConcurrencyConflict` → `[:retry, ...]`
- [ ] Version mismatch at commit → `ConcurrencyConflict` → `[:retry, ...]`, no budget consumed
- [ ] `saga.publish` resolves eagerly at call site (`MissingCorrelationError` surfaces in-block under retry policy — Task 7) and staged rows insert only in the commit with deterministic `event_id`s; block re-run does not double-insert
- [ ] After commit: staged jobs enqueued; parked events for the new state re-delivered in ledger order (`stalled` → `pending`, `stall_count` reset, job enqueued)
- [ ] Full chain: `order_placed` → `payment_settled` → `review_passed` drives OrderSaga to `completed` via `perform_enqueued_jobs`

**Steps:**

- [ ] **Step 1: Facade**

`lib/saga_forge/execution/facade.rb`:
```ruby
module SagaForge
  module Execution
    # The `saga` object yielded to forward blocks (§A.1 verbs). Everything is
    # staged in memory; the Runner commits it.
    class Facade
      attr_reader :correlation_id, :current_state, :context, :outcome, :staged_publishes

      def initialize(definition:, correlation_id:, current_state:, context:, source_event_id:)
        @definition = definition
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @source_event_id = source_event_id
        @staged_publishes = []
        @outcome = nil
      end

      def transition_to(state)
        unless @definition.declared?(state)
          raise UnknownStateError, "transition_to #{state.inspect} — undeclared state"
        end
        @outcome = [:transition_to, state.to_sym]
        nil
      end

      def stay
        if @current_state == Definition::START
          raise Error, "stay is not valid in start_with — there is no start state to remain in"
        end
        @outcome = :stay
        nil
      end

      def fail!(reason: nil)
        @outcome = [:fail, reason]
        throw :saga_forge_fail
      end

      # Staged publish (§A.2): resolve recipients NOW (call-site stack trace),
      # hold fully-built rows; the Runner inserts them inside its commit.
      def publish(event_name, **payload)
        rows = Router.resolve(event_name, payload)
        seq = @staged_publishes.size
        rows.each do |attrs|
          @staged_publishes << attrs.merge(event_id: "staged:#{@source_event_id}:#{seq}")
        end
        nil
      end
    end
  end
end
```

- [ ] **Step 2: Runner `execute!` + commit.** Replace the `execute!` stub and add private methods:

```ruby
def execute!(definition, state_row, current)
  handler = definition.handler_for(event.event_name)
  entry_version = state_row&.version || 0
  context = (state_row&.context || {}).deep_dup.with_indifferent_access

  facade = Facade.new(
    definition: definition,
    correlation_id: event.correlation_id,
    current_state: current,
    context: context,
    source_event_id: event.id
  )

  begin
    catch(:saga_forge_fail) do
      SagaForge.guarding_execution do
        handler.block.call(facade, event.payload.with_indifferent_access)
      end
    end
  rescue => error
    return handle_error(error, definition, handler) # Task 7 (until then: re-raise)
  end

  state_row = commit!(definition, state_row, current, entry_version, facade)
  after_commit_effects(definition, state_row, facade)
  [:done]
rescue ConcurrencyConflict
  [:retry, SagaForge.config.stall_wait]
end

private

def commit!(definition, state_row, current, entry_version, facade)
  failing = facade.outcome.is_a?(Array) && facade.outcome.first == :fail
  next_state = resolve_next_state(definition, current, facade.outcome)

  State.transaction do
    if state_row.nil?
      begin
        state_row = State.create!(
          saga_class: event.saga_class, correlation_id: event.correlation_id,
          current_state: next_state, version: entry_version, context: {}
        )
      rescue ActiveRecord::RecordNotUnique
        raise ConcurrencyConflict, "duplicate start for #{event.saga_class}##{event.correlation_id}"
      end
    end
    state_row.lock!
    raise ConcurrencyConflict, "version moved" if state_row.version != entry_version

    context = facade.context
    if failing
      meta = (context["__saga_forge"] ||= {})
      meta["failure_reason"] = facade.outcome.last
      meta["target"] = "compensated"
    end

    state_row.update!(current_state: next_state, version: entry_version + 1, context: context)
    event.update!(status: :processed, saga_forge_state_id: state_row.id, error: nil)

    unless failing # fail! discards staged publishes (§A.1)
      @inserted_rows = facade.staged_publishes.map { |attrs| Event.create!(attrs) }
    end
  end
  state_row
end

def resolve_next_state(definition, current, outcome)
  case outcome
  in nil then definition.successor_of(current).to_s
  in :stay then current.to_s
  in [:transition_to, target] then target.to_s
  in [:fail, _] then State::COMPENSATING.to_s
  end
end

def after_commit_effects(definition, state_row, facade)
  (@inserted_rows || []).each { |row| ExecutionJob.perform_later(row.id) }

  if state_row.current_state == State::COMPENSATING.to_s
    CompensationJob.perform_later(state_row.id) # Task 8
    return
  end

  redeliver_parked(definition, state_row)
  arm_timeouts(definition, state_row) # Task 9 (no-op until then)
end

def redeliver_parked(definition, state_row)
  names = definition.events_for_state(state_row.current_state).map(&:to_s)
  return if names.empty?
  Event.stalled.for_instance(event.saga_class, event.correlation_id)
    .where(event_name: names).ledger_order.each do |parked|
    parked.update!(status: :pending, stall_count: 0)
    ExecutionJob.perform_later(parked.id)
  end
end

def arm_timeouts(definition, state_row)
  # Task 9
end
```

Until Task 7, `handle_error` is:
```ruby
def handle_error(error, definition, handler)
  raise error
end
```
Until Task 8, guard the `CompensationJob` reference: define a placeholder `lib/saga_forge/compensation_job.rb` with an empty `perform(state_id)`.

- [ ] **Step 3: Commit-mechanics tests**

`test/execution_commit_test.rb`:
```ruby
require "test_helper"

class ExecutionCommitTest < SagaForge::TestCase
  def publish!(name, **payload)
    SagaForge.publish(name, event_id: "t:#{name}:#{SecureRandom.hex(4)}", **payload)
  end

  test "start event creates row at successor state and processes the event" do
    rows = publish!(:order_placed, order_id: 7, shipment_ref: "S1", total: 10)
    row = rows.find { |r| r.saga_class == "OrderSaga" }
    SagaForge::Execution::Runner.new(row).call
    state = OrderSaga.find_by_correlation(7)
    assert_equal "awaiting_settlement", state.current_state
    assert_equal 1, state.version
    assert_equal 10, state.context["total"]
    assert row.reload.processed?
    assert_equal state.id, row.saga_forge_state_id
  end

  test "version mismatch returns retry outcome and commits nothing" do
    state = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "9",
      current_state: "awaiting_settlement", version: 3)
    e = SagaForge::Event.create!(event_id: "v:1", saga_class: "OrderSaga", correlation_id: "9",
      event_name: "payment_settled", payload: {})
    runner = SagaForge::Execution::Runner.new(e)
    # Simulate a concurrent commit landing between block run and commit:
    runner.define_singleton_method(:commit!) do |*args|
      state.update_columns(version: 4)
      super(*args)
    end
    # entry_version was read as 3; concurrent bump to 4 → conflict
    outcome, = runner.call
    assert_equal :retry, outcome
    assert e.reload.pending?
  end

  test "staged publish inserts only at commit with deterministic ids; delivered to recipient" do
    publish_and_run(:order_placed, order_id: 7, shipment_ref: "S1", total: 10)
    e = publish_row(:payment_settled, order_id: 7)
    SagaForge::Execution::Runner.new(e).call
    staged = SagaForge::Event.where("event_id LIKE ?", "staged:#{e.id}:%")
    assert_equal 1, staged.count # :order_fulfilled has no registered recipients in fixtures → 0; use a fixture that does
  end

  test "stay keeps state but bumps version" do
    # StaySaga fixture: during :counting, on: :tick { |saga, _| saga.context[:n] = saga.context[:n].to_i + 1; saga.stay if saga.context[:n] < 2 }
    publish_and_run(:start_counting, counter_id: 1)
    publish_and_run(:tick, counter_id: 1)
    s = StaySaga.find_by_correlation(1)
    assert_equal "counting", s.current_state
    assert_equal 2, s.version
    publish_and_run(:tick, counter_id: 1)
    assert_equal "done_counting", StaySaga.find_by_correlation(1).current_state
  end

  private

  def publish_row(name, **payload)
    SagaForge.publish(name, event_id: "t:#{name}:#{SecureRandom.hex(4)}", **payload)
      .find { |r| r.saga_class == "OrderSaga" }
  end

  def publish_and_run(name, **payload)
    SagaForge.publish(name, event_id: "t:#{name}:#{SecureRandom.hex(4)}", **payload)
      .each { |r| SagaForge::Execution::Runner.new(r).call }
  end
end
```

Add fixture `test/internal/app/sagas/stay_saga.rb`:
```ruby
class StaySaga < SagaForge::Base
  correlate_by :counter_id
  start_with(:start_counting) { |saga, _payload| saga.context[:n] = 0 }
  during(:counting, on: :tick) do |saga, _payload|
    saga.context[:n] = saga.context[:n].to_i + 1
    saga.stay if saga.context[:n] < 2
  end
  finish_with :done_counting
end
```
And a `FulfillmentListenerSaga` fixture registering `:order_fulfilled` so the staged-publish test has a real recipient:
```ruby
class FulfillmentListenerSaga < SagaForge::Base
  correlate_by :order_id
  start_with(:order_fulfilled) { |saga, _payload| saga.context[:notified] = true }
  finish_with :notified
end
```
(Adjust the staged-publish assertion: staged row count is 1, `saga_class` == "FulfillmentListenerSaga".)

- [ ] **Step 4: End-to-end flow test**

`test/saga_flow_test.rb`:
```ruby
require "test_helper"

class SagaFlowTest < SagaForge::TestCase
  test "full happy chain via enqueued jobs, out-of-order arrival heals via parking" do
    SagaForge.configure { |c| c.stall_budget = 1 } # park immediately for the test
    perform_enqueued_jobs do
      SagaForge.publish(:review_passed, event_id: "e3", order_id: 1)   # early — parks
    end
    assert SagaForge::Event.find_by(event_name: "review_passed").stalled?

    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "e1", order_id: 1, shipment_ref: "S1", total: 10)
      SagaForge.publish(:payment_settled, event_id: "e2", order_id: 1)
    end
    # payment_settled commit advanced to awaiting_review and re-delivered the parked review_passed
    state = OrderSaga.find_by_correlation(1)
    assert_equal "completed", state.current_state
    assert_equal %w[processed processed processed],
      state.events.ledger_order.map(&:status)
  end
end
```

- [ ] **Step 5: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: facade verbs, single-commit execution, staged publish delivery, parking re-delivery"
```

```json:metadata
{"files": ["lib/saga_forge/execution/facade.rb", "lib/saga_forge/execution/runner.rb"], "verifyCommand": "bundle exec rake test TEST=test/execution_commit_test.rb TEST=test/saga_flow_test.rb", "acceptanceCriteria": ["verbs + fall-through", "commit atomicity + version check", "staged exactly-once", "parked re-delivery in ledger order", "e2e chain"], "requiresUserVerification": false}
```

---

### Task 7: Retry-policy integration and failed events

**Goal:** Errors in blocks route through the resolved policy; attempts/budgets tracked on the event row; exhaustion/unmatched → `failed` with traceback; nothing escapes to ActiveJob dead-letter.

**Files:**
- Modify: `lib/saga_forge/execution/runner.rb` (real `handle_error`)
- Test: `test/retry_integration_test.rb`

**Acceptance Criteria:**
- [ ] Retryable error: `attempts` incremented, `[:retry, backoff]` returned, event stays `pending`
- [ ] Composite: budget tracked per `budget_key` in `retry_budgets`; unmatched error fails fast
- [ ] Exhaustion: event `failed`, `error` json has `class`/`message`/`backtrace`; saga row untouched; halt now active for the instance
- [ ] `MissingCorrelationError` from an in-block `saga.publish` goes through the same path (it's a StandardError raised in the block)

**Steps:**

- [ ] **Step 1: `handle_error`**

```ruby
def handle_error(error, definition, handler)
  policy = definition.retry_policy_for(handler)
  attempts = event.attempts + 1
  budgets = (event.retry_budgets || {}).dup
  updates = {attempts: attempts}

  backoff = policy.retry_backoff(error, attempts: attempts) do |budget_key|
    budgets[budget_key] = budgets.fetch(budget_key, 0) + 1
    updates[:retry_budgets] = budgets
    budgets[budget_key]
  end

  if backoff
    event.update!(**updates)
    [:retry, backoff]
  else
    event.update!(**updates, status: :failed, error: {
      "class" => error.class.name,
      "message" => error.message.to_s.truncate(10_000),
      "backtrace" => Array(error.backtrace).first(50)
    })
    Rails.logger.error { "[saga_forge] #{event.saga_class}##{event.correlation_id} #{event.event_name} failed: #{error.class}: #{error.message}" }
    [:done]
  end
end
```

Note: a plain `RetryPolicy#retry_backoff` ignores the block (chrono contract), so `retry_budgets` is only written for composites — matching the spec (§A.5 "per-error budgets tracked on the event row").

- [ ] **Step 2: Fixture** `test/internal/app/sagas/flaky_saga.rb`:
```ruby
class FlakyError < StandardError; end
class FatalError < StandardError; end

class FlakySaga < SagaForge::Base
  correlate_by :id
  retry_policy SagaForge::RetryPolicy.new(retry_on: [FlakyError], max_attempts: 3),
    SagaForge::RetryPolicy.new(retry_on: [FatalError], max_attempts: 1)

  start_with :flaky_started do |saga, payload|
    raise FlakyError if payload[:mode] == "flaky"
    raise FatalError if payload[:mode] == "fatal"
    raise "unmatched" if payload[:mode] == "unmatched"
  end
  finish_with :done
end
```

- [ ] **Step 3: Tests**

`test/retry_integration_test.rb`:
```ruby
require "test_helper"

class RetryIntegrationTest < SagaForge::TestCase
  def row(mode:, corr: "1")
    SagaForge.publish(:flaky_started, event_id: "f:#{mode}:#{corr}", id: corr, mode: mode).first
  end

  test "retryable error increments attempts and budget, stays pending" do
    e = row(mode: "flaky")
    outcome, wait = SagaForge::Execution::Runner.new(e).call
    assert_equal :retry, outcome
    assert wait.to_f.positive?
    e.reload
    assert e.pending?
    assert_equal 1, e.attempts
    assert_equal 1, e.retry_budgets["FlakyError"]
  end

  test "exhaustion marks failed with traceback and activates halt" do
    e = row(mode: "fatal")
    SagaForge::Execution::Runner.new(e).call # attempt 1 of max 1 → failed
    e.reload
    assert e.failed?
    assert_equal "FatalError", e.error["class"]
    assert e.error["backtrace"].any?

    sibling = SagaForge::Event.create!(event_id: "sib", saga_class: "FlakySaga",
      correlation_id: "1", event_name: "flaky_started", payload: {})
    assert_equal [:done], SagaForge::Execution::Runner.new(sibling).call
    assert sibling.reload.pending?
  end

  test "unmatched error fails fast on first attempt" do
    e = row(mode: "unmatched", corr: "2")
    SagaForge::Execution::Runner.new(e).call
    assert e.reload.failed?
    assert_equal 1, e.attempts
  end

  test "budgets are independent per declared-error key" do
    e = row(mode: "flaky", corr: "3")
    3.times { SagaForge::Execution::Runner.new(e.reload).call }
    assert e.reload.failed? # FlakyError budget (3) spent
    assert_equal 3, e.retry_budgets["FlakyError"]
  end
end
```

- [ ] **Step 4: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: retry policy integration with per-error budgets and failed-event isolation"
```

```json:metadata
{"files": ["lib/saga_forge/execution/runner.rb", "test/internal/app/sagas/flaky_saga.rb"], "verifyCommand": "bundle exec rake test TEST=test/retry_integration_test.rb", "acceptanceCriteria": ["retry with backoff", "budgets on row", "failed + halt", "fail-fast unmatched"], "requiresUserVerification": false}
```

---

### Task 8: `fail!`, compensation runner, `:compensated` / `:cancelled`

**Goal:** Derived LIFO compensation (§A.4): processed events → `compensate:` registry → dedupe → LIFO, per-compensation commits, tolerant retries, terminal transition.

**Files:**
- Create: `lib/saga_forge/compensation_runner.rb`, `lib/saga_forge/execution/compensation_facade.rb`
- Modify: `lib/saga_forge/compensation_job.rb` (real implementation)
- Test: `test/compensation_test.rb`

**Acceptance Criteria:**
- [ ] `fail!` in a block: event `processed`, context committed (snapshot), staged publishes discarded, state → `compensating`, `CompensationJob` enqueued
- [ ] Owed list = processed events in ledger order → mapped → deduped (a `stay` loop owes one run) → reversed (LIFO)
- [ ] Each compensation commits `context` + appends its name to `__saga_forge.compensated` before the next runs; crash-resume skips completed ones
- [ ] Compensation blocks get a facade with `context`/`correlation_id`/`publish` only (staged rows insert per-compensation-commit with deterministic ids); guard flag active
- [ ] Compensation errors: tolerant default (`compensation_default`) unless the compensation's forward handler declared nothing — always `compensation_default` (spec: site default for compensation blocks); exhaustion → `comp_error` recorded, `Rails.logger.error { }`, saga stays `compensating`, `[:retry→done]` stops
- [ ] Drained list → `current_state` = target (`compensated` or `cancelled`), version bumped
- [ ] `fail!` with empty ledger (start block fails) still terminates `:compensated` with reason recorded

**Steps:**

- [ ] **Step 1: CompensationFacade**

`lib/saga_forge/execution/compensation_facade.rb`:
```ruby
module SagaForge
  module Execution
    # Yielded to compensation blocks: context is the snapshot (§A.4).
    # No transition verbs — rollback has one direction.
    class CompensationFacade
      attr_reader :correlation_id, :current_state, :context, :staged_publishes

      def initialize(correlation_id:, current_state:, context:, id_prefix:)
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @id_prefix = id_prefix
        @staged_publishes = []
      end

      def publish(event_name, **payload)
        rows = Router.resolve(event_name, payload)
        seq = @staged_publishes.size
        rows.each { |attrs| @staged_publishes << attrs.merge(event_id: "#{@id_prefix}:#{seq}") }
        nil
      end
    end
  end
end
```

- [ ] **Step 2: CompensationRunner**

`lib/saga_forge/compensation_runner.rb`:
```ruby
module SagaForge
  # Rollback is derived, not stored (§A.4): owed = processed events, mapped
  # through the compensate: registry, deduped, run LIFO with a commit per
  # compensation. Progress lives in context["__saga_forge"].
  class CompensationRunner
    attr_reader :state

    def initialize(state)
      @state = state
    end

    def call
      definition = state.saga_definition
      meta = (state.context["__saga_forge"] || {})
      done = meta["compensated"] || []
      owed = owed_compensations(definition) - done.map(&:to_sym)

      owed.each do |name|
        outcome = run_one(definition, name)
        return outcome unless outcome == :continue
        state.reload
      end

      finalize!
      [:done]
    end

    private

    def owed_compensations(definition)
      state.events.processed.ledger_order
        .filter_map { |e| definition.handler_for(e.event_name)&.compensate }
        .uniq
        .reverse
    end

    def run_one(definition, name)
      block = definition.compensations.fetch(name)
      context = state.context.deep_dup.with_indifferent_access
      facade = Execution::CompensationFacade.new(
        correlation_id: state.correlation_id,
        current_state: state.current_state,
        context: context,
        id_prefix: "staged:comp:#{state.id}:#{name}"
      )

      begin
        SagaForge.guarding_execution { block.call(facade) }
      rescue => error
        return handle_comp_error(name, error)
      end

      inserted = nil
      State.transaction do
        state.lock!
        context = facade.context
        meta = (context["__saga_forge"] ||= {})
        (meta["compensated"] ||= []) << name.to_s
        state.update!(context: context, version: state.version + 1)
        inserted = facade.staged_publishes.map { |attrs| Event.create!(attrs) }
      rescue ActiveRecord::RecordNotUnique
        # crash-after-commit re-run: staged rows already exist — fine
        inserted = []
        raise ActiveRecord::Rollback
      end
      Array(inserted).each { |row| ExecutionJob.perform_later(row.id) }
      :continue
    end

    def handle_comp_error(name, error)
      meta = (state.context["__saga_forge"] ||= {})
      attempts = (meta["comp_attempts"] ||= {})
      attempts[name.to_s] = attempts.fetch(name.to_s, 0) + 1
      count = attempts[name.to_s]
      state.update!(context: state.context)

      backoff = RetryPolicy.compensation_default.retry_backoff(error, attempts: count)
      if backoff
        [:retry, backoff]
      else
        meta["comp_error"] = {"name" => name.to_s, "class" => error.class.name, "message" => SagaForge.safe_error_message(error.message, 5_000)}
        state.update!(context: state.context)
        Rails.logger.error { "[saga_forge] compensation #{name} exhausted for #{state.saga_class}##{state.correlation_id}: #{error.class}: #{error.message}" }
        [:done] # stuck in :compensating; operator re-runs compensate! after a fix
      end
    end

    def finalize!
      target = state.context.dig("__saga_forge", "target") || "compensated"
      State.transaction do
        state.lock!
        state.update!(current_state: target, version: state.version + 1)
      end
    end
  end
end
```

Note on the `RecordNotUnique` rescue inside the transaction: a duplicate staged insert means a previous run of this same compensation already committed (crash between commit and the next reload). Rolling back this inner attempt and continuing is correct — but the `compensated` append also rolled back, so re-derive: simplest correct behavior is `return :continue` after the rollback **without** re-appending (the prior committed run already appended the name). Verify this in the crash test; if the prior run did NOT append (impossible — same transaction), the LIFO loop re-runs it next call.

- [ ] **Step 3: CompensationJob**

`lib/saga_forge/compensation_job.rb`:
```ruby
module SagaForge
  class CompensationJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(state_id)
      state = State.find_by(id: state_id)
      return unless state
      return unless state.current_state == State::COMPENSATING.to_s

      outcome, wait = CompensationRunner.new(state).call
      retry_job(wait: wait) if outcome == :retry
    end
  end
end
```

- [ ] **Step 4: Tests**

`test/compensation_test.rb`:
```ruby
require "test_helper"

class CompensationTest < SagaForge::TestCase
  test "fail! compensates processed steps LIFO and lands in :compensated" do
    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "c1", order_id: 5, shipment_ref: "S", total: 9)
      SagaForge.publish(:payment_settled, event_id: "c2", order_id: 5)
      SagaForge.publish(:payment_failed, event_id: "c3", order_id: 5, code: "card_declined")
    end
    s = OrderSaga.find_by_correlation(5)
    assert_equal "compensated", s.current_state
    meta = s.context["__saga_forge"]
    assert_equal "card_declined", meta["failure_reason"]
    # LIFO: release_stock (from payment_settled) before refund (from order_placed)
    assert_equal %w[release_stock refund], meta["compensated"]
    assert_equal true, s.context["released"]
    assert_equal ["ch_5"], s.context["refunded"]
  end

  test "fail! discards staged publishes from the failing block" do
    # OrderSaga's payment_failed handler publishes nothing; assert no staged rows exist for its event
    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "d1", order_id: 6, shipment_ref: "S", total: 9)
      SagaForge.publish(:payment_failed, event_id: "d2", order_id: 6, code: "x")
    end
    failing_event = SagaForge::Event.find_by(event_name: "payment_failed", correlation_id: "6")
    assert_equal 0, SagaForge::Event.where("event_id LIKE ?", "staged:#{failing_event.id}:%").count
  end

  test "fail! with empty ledger terminates :compensated with reason" do
    # FailFastSaga fixture: start_with(:doomed) { |saga, p| saga.fail! reason: "no" }
    perform_enqueued_jobs { SagaForge.publish(:doomed, event_id: "e1", id: 1) }
    s = FailFastSaga.find_by_correlation(1)
    assert_equal "compensated", s.current_state
    assert_equal "no", s.context.dig("__saga_forge", "failure_reason")
    assert_empty s.context.dig("__saga_forge", "compensated") || []
  end

  test "stay loop owes one compensation run" do
    # PackSaga fixture: stay-loop on :item_packed with compensate: :unpack, then :sealed advances; fail on :audit_failed
    perform_enqueued_jobs do
      SagaForge.publish(:pack_started, event_id: "p0", box_id: 1)
      3.times { |i| SagaForge.publish(:item_packed, event_id: "p#{i + 1}", box_id: 1) }
      SagaForge.publish(:audit_failed, event_id: "p9", box_id: 1)
    end
    s = PackSaga.find_by_correlation(1)
    assert_equal "compensated", s.current_state
    assert_equal 1, s.context["unpack_runs"]
  end

  test "compensation exhaustion records comp_error and stays compensating" do
    # BrokenCompSaga fixture: compensation raises every time
    perform_enqueued_jobs do
      SagaForge.publish(:broken_started, event_id: "b1", id: 1)
      SagaForge.publish(:broken_go, event_id: "b2", id: 1)
    end
    # drain the retry chain manually with a low-attempt stub:
    s = BrokenCompSaga.find_by_correlation(1)
    SagaForge::RetryPolicy.stub(:compensation_default, SagaForge::RetryPolicy.new(max_attempts: 1)) do
      SagaForge::CompensationRunner.new(s.reload).call
    end
    s.reload
    assert_equal "compensating", s.current_state
    assert_equal "explode", s.context.dig("__saga_forge", "comp_error", "name")
  end
end
```

Fixtures to add under `test/internal/app/sagas/`:
```ruby
# fail_fast_saga.rb
class FailFastSaga < SagaForge::Base
  correlate_by :id
  start_with(:doomed) { |saga, _p| saga.fail! reason: "no" }
  finish_with :never
end

# pack_saga.rb
class PackSaga < SagaForge::Base
  correlate_by :box_id
  start_with(:pack_started) { |saga, _p| saga.context[:items] = 0 }
  during(:packing, on: :item_packed, compensate: :unpack) do |saga, _p|
    saga.context[:items] = saga.context[:items].to_i + 1
    saga.stay
  end
  during(:packing, on: :audit_failed) { |saga, p| saga.fail! reason: "audit" }
  finish_with :packed
  compensation(:unpack) { |saga| saga.context[:unpack_runs] = saga.context[:unpack_runs].to_i + 1 }
end

# broken_comp_saga.rb
class BrokenCompSaga < SagaForge::Base
  correlate_by :id
  start_with(:broken_started, compensate: :explode) { |saga, _p| }
  during(:running, on: :broken_go) { |saga, _p| saga.fail! reason: "go" }
  finish_with :done
  compensation(:explode) { |_saga| raise "compensation bug" }
end
```

Note: `PackSaga`'s `audit_failed` fail comes while `stay`-looping; the `item_packed` events are all `processed`, `unpack` dedupes to one run.

- [ ] **Step 5: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: derived LIFO compensation with per-step commits and tolerant retries"
```

```json:metadata
{"files": ["lib/saga_forge/compensation_runner.rb", "lib/saga_forge/compensation_job.rb", "lib/saga_forge/execution/compensation_facade.rb"], "verifyCommand": "bundle exec rake test TEST=test/compensation_test.rb", "acceptanceCriteria": ["LIFO derived from ledger", "dedupe stay loops", "empty-ledger fail!", "comp exhaustion recorded"], "requiresUserVerification": false}
```

---

### Task 9: Timeouts

**Goal:** `timeout:`/`on_timeout:` per handler (§A.1): armed at commit, version-fenced, clock resets per handled event.

**Files:**
- Create: `lib/saga_forge/timeout_job.rb`
- Modify: `lib/saga_forge/execution/runner.rb` (`arm_timeouts` real implementation)
- Test: `test/timeout_test.rb`

**Acceptance Criteria:**
- [ ] Entering (or `stay`-ing in) a state arms one `TimeoutJob` per handler of that state declaring `timeout:`, scheduled `wait: handler.timeout`, args `(state_id, event_name, version-after-commit)`
- [ ] Stale fire (version moved) → silent discard
- [ ] `on_timeout: :fail!` → state → `compensating` with reason `"timeout"`, `CompensationJob` enqueued
- [ ] `on_timeout: :some_state` → locked version-checked transition, parked re-delivery + re-arm for the new state

**Steps:**

- [ ] **Step 1: `arm_timeouts` in Runner**

```ruby
def arm_timeouts(definition, state_row)
  current = state_row.current_state.to_sym
  definition.events_for_state(current).each do |event_name|
    handler = definition.handler_for(event_name)
    next unless handler.timeout
    TimeoutJob.set(wait: handler.timeout)
      .perform_later(state_row.id, event_name.to_s, state_row.version)
  end
end
```

- [ ] **Step 2: TimeoutJob**

`lib/saga_forge/timeout_job.rb`:
```ruby
module SagaForge
  # A stale timer firing late is discarded by the version fence — the same
  # principle that powers stalling. The clock resets on each handled event
  # because every commit bumps version and re-arms (§A.1).
  class TimeoutJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform(state_id, event_name, armed_version)
      state = State.find_by(id: state_id)
      return unless state
      return if state.version != armed_version # stale timer

      definition = state.saga_definition
      handler = definition.handler_for(event_name)
      return unless handler&.timeout

      case handler.on_timeout
      when :fail!, "fail!"
        State.transaction do
          state.lock!
          return if state.version != armed_version
          meta = (state.context["__saga_forge"] ||= {})
          meta["failure_reason"] = "timeout"
          meta["target"] = "compensated"
          state.update!(current_state: State::COMPENSATING.to_s, version: state.version + 1, context: state.context)
        end
        CompensationJob.perform_later(state.id)
      else
        target = handler.on_timeout.to_s
        raise UnknownStateError, "on_timeout: #{target} undeclared" unless definition.declared?(target)
        State.transaction do
          state.lock!
          return if state.version != armed_version
          state.update!(current_state: target, version: state.version + 1)
        end
        redeliver_and_rearm(definition, state)
      end
    end

    private

    def redeliver_and_rearm(definition, state)
      names = definition.events_for_state(state.current_state).map(&:to_s)
      Event.stalled.for_instance(state.saga_class, state.correlation_id)
        .where(event_name: names).ledger_order.each do |parked|
        parked.update!(status: :pending, stall_count: 0)
        ExecutionJob.perform_later(parked.id)
      end
      definition.events_for_state(state.current_state.to_sym).each do |event_name|
        handler = definition.handler_for(event_name)
        next unless handler.timeout
        TimeoutJob.set(wait: handler.timeout).perform_later(state.id, event_name.to_s, state.version)
      end
    end
  end
end
```

- [ ] **Step 3: Fixture + tests**

`test/internal/app/sagas/timeout_saga.rb`:
```ruby
class TimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:t_started, compensate: :t_undo) { |saga, _p| saga.context[:started] = true }
  during(:waiting, on: :t_arrived, timeout: 30.minutes, on_timeout: :fail!) { |saga, _p| }
  finish_with :done
  compensation(:t_undo) { |saga| saga.context[:undone] = true }
end

class TimeoutBranchSaga < SagaForge::Base
  correlate_by :id
  start_with(:tb_started) { |saga, _p| }
  during(:waiting_fast, on: :tb_fast, timeout: 5.minutes, on_timeout: :waiting_slow) { |saga, _p| }
  during(:waiting_slow, on: :tb_slow) { |saga, _p| }
  finish_with :finished
end
```

`test/timeout_test.rb`:
```ruby
require "test_helper"

class TimeoutTest < SagaForge::TestCase
  test "commit arms a timeout job with post-commit version" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t1", id: 1)
    end
    s = TimeoutSaga.find_by_correlation(1)
    armed = enqueued_jobs.select { |j| j["job_class"] == "SagaForge::TimeoutJob" }
    assert_equal 1, armed.size
    assert_equal [s.id, "t_arrived", 1], armed.first["arguments"].first(3)
  end

  test "stale timer discards silently" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t2", id: 2)
    end
    s = TimeoutSaga.find_by_correlation(2)
    SagaForge::TimeoutJob.perform_now(s.id, "t_arrived", 99) # wrong version
    assert_equal "waiting", s.reload.current_state
  end

  test "on_timeout fail! compensates" do
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:t_started, event_id: "t3", id: 3)
    end
    s = TimeoutSaga.find_by_correlation(3)
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "t_arrived", s.version)
    end
    s.reload
    assert_equal "compensated", s.current_state
    assert_equal "timeout", s.context.dig("__saga_forge", "failure_reason")
    assert_equal true, s.context["undone"]
  end

  test "on_timeout state branch transitions and re-delivers parked" do
    SagaForge.configure { |c| c.stall_budget = 1 }
    perform_enqueued_jobs(only: SagaForge::ExecutionJob) do
      SagaForge.publish(:tb_started, event_id: "t4", id: 4)
      SagaForge.publish(:tb_slow, event_id: "t5", id: 4) # early → parks
    end
    s = TimeoutBranchSaga.find_by_correlation(4)
    perform_enqueued_jobs do
      SagaForge::TimeoutJob.perform_now(s.id, "tb_fast", s.version)
    end
    assert_equal "finished", s.reload.current_state # parked tb_slow re-delivered and processed
  end
end
```

- [ ] **Step 4: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: version-fenced timeouts with fail! and branch actions"
```

```json:metadata
{"files": ["lib/saga_forge/timeout_job.rb", "lib/saga_forge/execution/runner.rb"], "verifyCommand": "bundle exec rake test TEST=test/timeout_test.rb", "acceptanceCriteria": ["armed at commit", "version fence", "fail! and branch actions", "clock resets per event"], "requiresUserVerification": false}
```

---

### Task 10: Sweeper and retention jobs

**Goal:** The delivery guarantee (§A.2) and retention pruning (§A.6).

**Files:**
- Create: `lib/saga_forge/sweeper_job.rb`, `lib/saga_forge/retention_job.rb`
- Test: `test/sweeper_test.rb`

**Acceptance Criteria:**
- [ ] `SweeperJob` re-enqueues `pending` rows older than `sweep_interval` (batch via `find_each`); processed/failed untouched
- [ ] **(added after Task 6 review)** `SweeperJob` also closes the two post-commit crash holes: (a) sagas sitting in `:compensating` older than `sweep_interval` get `CompensationJob.perform_later` re-enqueued (the fail!→handoff is otherwise a once-only hint); (b) `stalled` events whose saga's `current_state` now equals their registered state get re-delivered (crash between commit and `redeliver_parked` otherwise strands them — the saga is waiting on exactly that event)
- [ ] **(added after Task 8 review)** The `:compensating` re-enqueue in (a) MUST skip sagas whose `context["__saga_forge"]["comp_error"]` is present — those exhausted their tolerant retries and are operator-recovery-only (`compensate!` after a code fix); blind re-enqueue would re-run the broken block once per sweep forever and grow `comp_attempts` unboundedly
- [ ] `RetentionJob` deletes `processed` events older than `retention` whose saga is in a terminal state; keeps everything for active sagas (compensation derives from history)
- [ ] README documents Solid Queue `recurring.yml` scheduling for both (written in Task 13)

**Steps:**

- [ ] **Step 1: Jobs**

`lib/saga_forge/sweeper_job.rb`:
```ruby
module SagaForge
  # The pending row is the obligation; enqueues are hints; this is the
  # guarantee (§A.2). Re-enqueueing an already-delivered row is harmless —
  # ExecutionJob's processed-skip and halt checks absorb it.
  class SweeperJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform
      Event.pending.where(created_at: ..SagaForge.config.sweep_interval.ago).find_each do |event|
        ExecutionJob.perform_later(event.id)
      end
    end
  end
end
```

`lib/saga_forge/retention_job.rb`:
```ruby
module SagaForge
  # Prunes processed events past retention — but only for sagas already in a
  # terminal state: active sagas derive compensation from their history (§A.6).
  class RetentionJob < ActiveJob::Base
    queue_as { SagaForge.config.job_queue }

    def perform
      cutoff = SagaForge.config.retention.ago
      Event.processed.where(created_at: ..cutoff).find_each do |event|
        state = event.state
        next unless state
        definition = state.saga_class.safe_constantize&.definition
        next unless definition
        event.destroy! if definition.terminal?(state.current_state)
      end
    end
  end
end
```

- [ ] **Step 2: Tests**

`test/sweeper_test.rb`:
```ruby
require "test_helper"

class SweeperTest < SagaForge::TestCase
  test "sweeper re-enqueues aged pending rows only" do
    old_pending = SagaForge::Event.create!(event_id: "sw1", saga_class: "OrderSaga",
      correlation_id: "1", event_name: "order_placed", payload: {}, created_at: 5.minutes.ago)
    SagaForge::Event.create!(event_id: "sw2", saga_class: "OrderSaga",
      correlation_id: "1", event_name: "order_placed", payload: {}) # fresh
    SagaForge::Event.create!(event_id: "sw3", saga_class: "OrderSaga",
      correlation_id: "1", event_name: "order_placed", payload: {},
      status: :stalled, created_at: 5.minutes.ago)

    assert_enqueued_with(job: SagaForge::ExecutionJob, args: [old_pending.id]) do
      SagaForge::SweeperJob.perform_now
    end
    assert_enqueued_jobs 1, only: SagaForge::ExecutionJob
  end

  test "retention prunes processed events of terminal sagas only" do
    terminal = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "1", current_state: "completed")
    active = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "2", current_state: "awaiting_settlement")
    prunable = SagaForge::Event.create!(event_id: "r1", saga_class: "OrderSaga", correlation_id: "1",
      event_name: "order_placed", status: :processed, state: terminal, created_at: 100.days.ago)
    kept_active = SagaForge::Event.create!(event_id: "r2", saga_class: "OrderSaga", correlation_id: "2",
      event_name: "order_placed", status: :processed, state: active, created_at: 100.days.ago)
    kept_fresh = SagaForge::Event.create!(event_id: "r3", saga_class: "OrderSaga", correlation_id: "1",
      event_name: "payment_settled", status: :processed, state: terminal)

    SagaForge::RetentionJob.perform_now
    refute SagaForge::Event.exists?(prunable.id)
    assert SagaForge::Event.exists?(kept_active.id)
    assert SagaForge::Event.exists?(kept_fresh.id)
  end
end
```

- [ ] **Step 3: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: sweeper delivery guarantee and terminal-only retention pruning"
```

```json:metadata
{"files": ["lib/saga_forge/sweeper_job.rb", "lib/saga_forge/retention_job.rb"], "verifyCommand": "bundle exec rake test TEST=test/sweeper_test.rb", "acceptanceCriteria": ["aged pending swept", "terminal-only pruning"], "requiresUserVerification": false}
```

---

### Task 11: Operator API (`retry_stalled!`, `resume!`, `compensate!`, `cancel!`)

**Goal:** The §A.7 recovery surface on `SagaForge::State`.

**Files:**
- Modify: `lib/saga_forge/state.rb`
- Test: `test/operator_api_test.rb`

**Acceptance Criteria:**
- [ ] `retry_stalled!`: stalled events → `pending`, `stall_count: 0`, enqueued (ledger order)
- [ ] `resume!`: failed events → `pending`, `attempts: 0`, `retry_budgets: {}`, `error: nil`, enqueued
- [ ] `compensate!`: warns via `Rails.logger.warn { }` when failed events exist (resume-then-compensate, §A.4); sets target `compensated`, locked transition to `compensating`, enqueues `CompensationJob`; no-op on terminal sagas
- [ ] `cancel!(reason:)`: same but target `cancelled` with reason recorded

**Steps:**

- [ ] **Step 1: Implement.** Add to `lib/saga_forge/state.rb`:

```ruby
def retry_stalled!
  events.stalled.ledger_order.each do |e|
    e.update!(status: :pending, stall_count: 0)
    ExecutionJob.perform_later(e.id)
  end
end

def resume!
  events.failed.ledger_order.each do |e|
    e.update!(status: :pending, attempts: 0, retry_budgets: {}, error: nil)
    ExecutionJob.perform_later(e.id)
  end
end

def compensate!(target: COMPENSATED, reason: nil)
  if events.failed.exists?
    Rails.logger.warn { "[saga_forge] compensate! with failed events on #{saga_class}##{correlation_id} — failed steps imply no compensation and left no context; resume!, then compensate (§resume-then-compensate)" }
  end
  return if saga_definition.terminal?(current_state) || current_state == COMPENSATING.to_s

  self.class.transaction do
    lock!
    meta = (context["__saga_forge"] ||= {})
    meta["target"] = target.to_s
    meta["failure_reason"] = reason if reason
    update!(current_state: COMPENSATING.to_s, version: version + 1, context: context)
  end
  CompensationJob.perform_later(id)
end

def cancel!(reason:)
  compensate!(target: CANCELLED, reason: reason)
end
```

- [ ] **Step 2: Tests**

`test/operator_api_test.rb`:
```ruby
require "test_helper"

class OperatorApiTest < SagaForge::TestCase
  test "retry_stalled! re-delivers parked events" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "1", current_state: "awaiting_settlement")
    e = SagaForge::Event.create!(event_id: "o1", saga_class: "OrderSaga", correlation_id: "1",
      event_name: "payment_settled", status: :stalled, stall_count: 40, state: s)
    assert_enqueued_with(job: SagaForge::ExecutionJob, args: [e.id]) { s.retry_stalled! }
    assert e.reload.pending?
    assert_equal 0, e.stall_count
  end

  test "resume! resets failed events fully" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "2", current_state: "awaiting_settlement")
    e = SagaForge::Event.create!(event_id: "o2", saga_class: "OrderSaga", correlation_id: "2",
      event_name: "payment_settled", status: :failed, attempts: 3,
      retry_budgets: {"*" => 3}, error: {"class" => "X"}, state: s)
    s.resume!
    e.reload
    assert e.pending?
    assert_equal 0, e.attempts
    assert_equal({}, e.retry_budgets)
    assert_nil e.error
  end

  test "cancel! compensates then lands in :cancelled with reason" do
    perform_enqueued_jobs do
      SagaForge.publish(:order_placed, event_id: "o3", order_id: 3, shipment_ref: "S", total: 1)
    end
    s = OrderSaga.find_by_correlation(3)
    perform_enqueued_jobs { s.cancel!(reason: "operator") }
    s.reload
    assert_equal "cancelled", s.current_state
    assert_equal "operator", s.context.dig("__saga_forge", "failure_reason")
    assert_equal ["refund"], s.context.dig("__saga_forge", "compensated")
  end

  test "compensate! warns when failed events exist" do
    s = SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "4", current_state: "awaiting_settlement")
    SagaForge::Event.create!(event_id: "o4", saga_class: "OrderSaga", correlation_id: "4",
      event_name: "payment_settled", status: :failed, state: s)
    logged = capture_rails_log { s.compensate! }
    assert_match(/resume!/, logged)
  end

  private

  def capture_rails_log
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = old
  end
end
```

- [ ] **Step 3: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: operator recovery API — retry_stalled!, resume!, compensate!, cancel!"
```

```json:metadata
{"files": ["lib/saga_forge/state.rb"], "verifyCommand": "bundle exec rake test TEST=test/operator_api_test.rb", "acceptanceCriteria": ["four operator methods per §A.7", "resume-then-compensate warning"], "requiresUserVerification": false}
```

---

### Task 12: Generators (install + migrations, angarium pattern)

> **SUPERSEDED (2026-07-19, user direction):** the migration mechanism
> described below (`db/saga_forge_migrate/` + `saga_forge:migrations` +
> `ActiveRecord::Migration.copy`) was replaced with chrono_forge's
> template/`MigrationActions` pattern — migrations now live as generator
> templates under `lib/generators/saga_forge/templates/`, listed in an
> ordered `MIGRATIONS` array shared by `saga_forge:install` and the new
> `saga_forge:upgrade` generator, copied via `migration_template` with an
> idempotent glob-based skip check. `db/saga_forge_migrate/` was deleted.
> See the commit that made this change (`refactor: adopt chrono_forge's
> migration template pattern`) and `docs/superpowers/specs/2026-07-19-saga-forge-design.md`
> §2 for the current design. The rest of this section is kept as a historical
> record of the original (superseded) design.

**Goal:** `rails g saga_forge:install [--database=NAME]` writes the initializer and copies migrations to `db/migrate` or `db/NAME_migrate` via `ActiveRecord::Migration.copy`.

**Files:**
- Create: `lib/generators/saga_forge/install/install_generator.rb`, `lib/generators/saga_forge/install/templates/initializer.rb`, `lib/generators/saga_forge/install/USAGE`
- Create: `lib/generators/saga_forge/migrations/migrations_generator.rb`, `lib/generators/saga_forge/migrations/USAGE`
- Test: `test/generators_test.rb`

**Acceptance Criteria (mirror angarium's matrix):**
- [ ] `saga_forge:migrations` default → `db/migrate` with `.saga_forge.rb` suffix + origin comment; `--database=saga` → `db/saga_migrate` (nothing in `db/migrate`); `--database=primary` → `db/migrate`; no flag + `config.database = :billing` → `db/billing_migrate`; re-runs idempotent
- [ ] `saga_forge:install` writes initializer with `config.database` commented by default; `--database=saga` uncomments it to `:saga`; invokes migrations generator; prints database.yml stanza + `db:migrate:NAME` next steps

**Steps:**

- [ ] **Step 1: Migrations generator**

`lib/generators/saga_forge/migrations/migrations_generator.rb`:
```ruby
require "rails/generators"

module SagaForge
  module Generators
    # Copies the gem's migrations (db/saga_forge_migrate) into the host app.
    # Living outside db/migrate means Rails never auto-appends them to the
    # primary connection — this generator is the single install path.
    class MigrationsGenerator < Rails::Generators::Base
      class_option :database, type: :string, default: nil,
        desc: "Named database (from database.yml) whose db/NAME_migrate receives the migrations"

      def copy_migrations
        database = options[:database].presence || SagaForge.config.migrations_database
        dir = (database.nil? || database.to_s == "primary") ? "db/migrate" : "db/#{database}_migrate"

        copied = ActiveRecord::Migration.copy(
          File.join(destination_root, dir),
          {"saga_forge" => source_root}
        )
        say copied.empty? ? "No new migrations to copy." : "Copied #{copied.size} migration(s) to #{dir}."
      end

      def self.source_root
        File.expand_path("../../../../db/saga_forge_migrate", __dir__)
      end

      private

      def source_root = self.class.source_root
    end
  end
end
```

- [ ] **Step 2: Install generator + template**

`lib/generators/saga_forge/install/install_generator.rb`:
```ruby
require "rails/generators"

module SagaForge
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :database, type: :string, default: nil,
        desc: "Put saga_forge tables on this named database (from database.yml)"

      def copy_initializer
        template "initializer.rb", "config/initializers/saga_forge.rb"
      end

      def set_database_config
        return unless database
        gsub_file "config/initializers/saga_forge.rb",
          /# config\.database = :saga_forge/,
          "config.database = :#{database}"
      end

      def install_migrations
        invoke "saga_forge:migrations", [], database: database
      end

      def print_next_steps
        say "\nNext steps:", :green
        if database && database != "primary"
          say <<~MSG
            1. Add the database to config/database.yml:

               #{database}:
                 <<: *default
                 database: db/#{database}.sqlite3   # or your PG/MySQL database name
                 migrations_paths: db/#{database}_migrate

            2. Run: bin/rails db:migrate:#{database}
          MSG
        else
          say "1. Run: bin/rails db:migrate"
        end
      end

      private

      def database = options[:database].presence
    end
  end
end
```

`lib/generators/saga_forge/install/templates/initializer.rb`:
```ruby
SagaForge.configure do |config|
  # === Multi-database (optional) ===
  # Put saga_forge's two tables on a named database from database.yml.
  # Leaving this commented keeps them on the primary database.
  # config.database = :saga_forge
  #
  # Escape hatch for custom roles/shards — a raw connects_to hash (wins over
  # config.database):
  # config.connects_to = {database: {writing: :saga_forge, reading: :saga_forge_replica}}

  # === Engine tuning (defaults shown) ===
  # config.stall_wait     = 3.seconds   # early-event queue-spin wait
  # config.stall_budget   = 40          # spins before an event parks as stalled
  # config.sweep_interval = 30.seconds  # SweeperJob cadence (schedule it yourself)
  # config.retention      = 90.days     # processed-event pruning window (RetentionJob)
  # config.job_queue      = :sagas
  # config.primary_key_type = :uuid     # engine tables' PK type (default: host app convention)
end
```

`USAGE` files: one-paragraph descriptions with the flag documented.

- [ ] **Step 3: Tests** — port angarium's generator test approach (`Rails::Generators::TestCase`, destination `test/tmp/generator`, `prepare_destination`):

```ruby
require "test_helper"
require "rails/generators/test_case"
require "generators/saga_forge/install/install_generator"
require "generators/saga_forge/migrations/migrations_generator"

class MigrationsGeneratorTest < Rails::Generators::TestCase
  tests SagaForge::Generators::MigrationsGenerator
  destination File.expand_path("tmp/generator", __dir__)
  setup { prepare_destination; SagaForge.reset_configuration! }

  test "default copies into db/migrate with engine suffix" do
    run_generator
    file = Dir[File.join(destination_root, "db/migrate/*_create_saga_forge_tables.saga_forge.rb")].first
    assert file, "migration not copied"
    assert_match(/This migration comes from saga_forge/, File.read(file))
  end

  test "--database=saga copies into db/saga_migrate only" do
    run_generator %w[--database=saga]
    assert Dir[File.join(destination_root, "db/saga_migrate/*.saga_forge.rb")].any?
    assert_empty Dir[File.join(destination_root, "db/migrate/*")]
  end

  test "--database=primary uses db/migrate" do
    run_generator %w[--database=primary]
    assert Dir[File.join(destination_root, "db/migrate/*.saga_forge.rb")].any?
  end

  test "no flag falls back to config.migrations_database" do
    SagaForge.configure { |c| c.database = :billing }
    run_generator
    assert Dir[File.join(destination_root, "db/billing_migrate/*.saga_forge.rb")].any?
  end
end

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SagaForge::Generators::InstallGenerator
  destination File.expand_path("tmp/generator", __dir__)
  setup { prepare_destination; SagaForge.reset_configuration! }

  test "writes initializer with database commented" do
    run_generator
    assert_file "config/initializers/saga_forge.rb", /# config\.database = :saga_forge/
  end

  test "--database uncomments and persists the database" do
    run_generator %w[--database=saga]
    assert_file "config/initializers/saga_forge.rb", /^  config\.database = :saga$/
    assert Dir[File.join(destination_root, "db/saga_migrate/*.saga_forge.rb")].any?
  end
end
```

Note: `ActiveRecord::Migration.copy` needs the migration's timestamp-prefixed filename in `db/saga_forge_migrate/` — already true (`20260719000001_…`). The `SagaForge.primary_key_type` call inside the migration template is evaluated at *migration run* in the host app, which is exactly right.

- [ ] **Step 4: Run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: install and migrations generators with --database multi-DB support"
```

```json:metadata
{"files": ["lib/generators/saga_forge/install/install_generator.rb", "lib/generators/saga_forge/migrations/migrations_generator.rb", "lib/generators/saga_forge/install/templates/initializer.rb"], "verifyCommand": "bundle exec rake test TEST=test/generators_test.rb", "acceptanceCriteria": ["angarium generator matrix", "initializer rewrite", "idempotent re-runs"], "requiresUserVerification": false}
```

---

### Task 13: Durability torture tests, CI, README

**Goal:** chaotic_job fault-injection proving the atomicity invariants; GitHub Actions CI; README.

**Files:**
- Create: `test/durability_test.rb`
- Create: `.github/workflows/main.yml`, `Appraisals`
- Create: `README.md`
- Test: full suite

**Acceptance Criteria:**
- [ ] Ghost-cascade impossibility: a block that stages a publish then raises never surfaces the staged event, across every chaotic_job failure permutation
- [ ] **(added after Task 6 review)** Post-commit crash injection: crash between commit and CompensationJob enqueue → sweeper recovers the `:compensating` saga; crash between commit and `redeliver_parked` → sweeper re-delivers the matching stalled event
- [ ] Exactly-once: crash-after-commit re-delivery does not double-insert staged rows or re-run the block's committed effects (event stays `processed`)
- [ ] Version race: two concurrent runners for one instance — one commits, one conflicts and retries clean
- [ ] CI: sqlite + postgres lanes, `bundle exec rake`
- [ ] README: hero example from spec §A.1, install (generator + multi-DB), scheduling snippet for sweeper/retention (Solid Queue `recurring.yml`), operator API, link to spec

**Steps:**

- [ ] **Step 1: Durability tests** (consult chaotic_job's README in the chrono_forge Gemfile.lock version for exact API — `ChaoticJob::Journal`, `run_scenario`, glitch helpers):

```ruby
require "test_helper"

class DurabilityTest < SagaForge::TestCase
  # GlitchSaga fixture: start block stages a publish then raises on first attempt
  # (uses ChaoticJob or a class-level attempt counter):
  #
  # class GlitchSaga < SagaForge::Base
  #   cattr_accessor :attempts_seen, default: 0
  #   correlate_by :id
  #   start_with :g_started do |saga, _p|
  #     saga.publish :g_echo, id: saga.correlation_id
  #     GlitchSaga.attempts_seen += 1
  #     raise "glitch" if GlitchSaga.attempts_seen == 1
  #   end
  #   finish_with :done
  # end
  # class GlitchEchoSaga < SagaForge::Base — registers :g_echo
  test "no ghost cascade: staged publish from failed pass never surfaces" do
    GlitchSaga.attempts_seen = 0
    row = SagaForge.publish(:g_started, event_id: "g1", id: 1).first
    outcome, = SagaForge::Execution::Runner.new(row).call      # pass 1: raises → retry
    assert_equal :retry, outcome
    assert_equal 0, SagaForge::Event.where(event_name: "g_echo").count # nothing surfaced

    SagaForge::Execution::Runner.new(row.reload).call          # pass 2: commits
    assert_equal 1, SagaForge::Event.where(event_name: "g_echo").count # exactly one
  end

  test "re-delivery after commit is a processed-skip, no double insert" do
    row = SagaForge.publish(:g_started, event_id: "g2", id: 2).first
    GlitchSaga.attempts_seen = 99 # no glitch
    SagaForge::Execution::Runner.new(row).call
    assert_equal [:done], SagaForge::Execution::Runner.new(row.reload).call
    assert_equal 1, SagaForge::Event.where(event_name: "g_echo", correlation_id: "2").count
  end

  test "concurrent version race: loser retries cleanly" do
    # Two runners over the same instance/event pair; simulate by bumping the
    # version between one runner's read and commit (as in Task 6's test) and
    # assert the loser returns [:retry, _] with the event still pending and
    # exactly one processed outcome after the retry.
  end
end
```

Also add a chaotic_job scenario run if its API fits ActiveJob at this version (`run_scenario(job, glitch: ...)`) — treat as bonus coverage, keep deterministic tests above as the required ones.

- [ ] **Step 2: CI + Appraisals** — copy chrono_forge's `.github/workflows/main.yml` structure. The PG lane MUST run the publisher dedup tests (duplicate `event_id` publish inside an ambient transaction must not poison the caller's transaction — Postgres aborts transactions on statement error; the savepoint in `Publisher#insert_row` exists for exactly this and is unverifiable on sqlite). job 1 `bundle exec appraisal rake test` on ruby 3.2/3.3 sqlite; job 2 postgres service with `DB_ADAPTER=postgresql`. `Appraisals` file with `rails-7.1` and `rails-8.0`. Extend `test/internal/config/database.yml` with a postgresql variant keyed on `DB_ADAPTER` env (copy chrono_forge's `test/internal/config/database.yml` approach verbatim).

- [ ] **Step 2b: Solid Queue concurrency-key coverage** — add `solid_queue` as a dev dependency (Gemfile) and unit-test `ExecutionJob`'s `limits_concurrency` key lambda (found row → `"SagaLock:<class>:<corr>"`, missing row → `"SagaLock:none"`). Deferred from Task 5 because the constant isn't defined in the base test env.

- [ ] **Step 3: README** — hero example (spec §A.1 OrderFulfillmentSaga), quick start (`bundle add saga_forge`, `rails g saga_forge:install`, multi-DB flag), publish contract (`SagaForge.publish` vs `saga.publish` — one paragraph each), scheduling:

```yaml
# config/recurring.yml (Solid Queue)
saga_forge_sweeper:
  class: SagaForge::SweeperJob
  schedule: every 30 seconds
saga_forge_retention:
  class: SagaForge::RetentionJob
  schedule: every day at 4am
```

operator API table (§A.7), a link to `docs/superpowers/specs/2026-07-19-saga-forge-design.md`, and an operations note that expired-timer jobs are expected queue litter (every handled event in a `timeout:` state re-arms a fresh timer; stale ones fire dead and discard via the version fence — bounded by tick frequency × timeout duration).

- [ ] **Step 4: Full run and commit**

```bash
bundle exec rake
git add -A
git commit -m "feat: durability torture tests, CI matrix, README"
```

```json:metadata
{"files": ["test/durability_test.rb", ".github/workflows/main.yml", "README.md"], "verifyCommand": "bundle exec rake", "acceptanceCriteria": ["ghost-cascade impossible", "exactly-once staged inserts", "CI two lanes", "README complete"], "requiresUserVerification": false}
```

---

## Task Dependency Graph

```
T0 ──┬─ T1 ──┬─ T4 ── T5 ── T6 ──┬─ T7 ── T8 ── T11 ── T13
     ├─ T2 ──┼──────────────(T7)  ├─ T9 ──────────────(T13)
     └─ T3 ──┘                    └─ T10 ─────────────(T13)
T1 ── T12 ────────────────────────────────────────────(T13)
```

## Notes for the dashboard phase (carried from reviews)

- Failed START events have no `State` row, so `State#resume!` can't reach them — the dashboard needs either a class-level/Event-level resume helper or documented raw-event guidance for pre-state-creation failures (Task 11 review, issue 7).

## Deferred (explicitly out of this plan)

- **§A.8's best-effort chain-reachability/dead-end WARNING** (final review, Minor-1): consciously deferred — it's advisory-only, inherently incomplete (jumps are opaque), and the dashboard phase's graph rendering is the natural home for surfacing unreachable states visually.
- `saga_forge-dashboard` engine gem (phase 2 — its own plan)
- Release tooling (git-cliff rake tasks) — comes with the first release, alongside phase 2
- strong_migrations CI lane hardening, `site/` docs page

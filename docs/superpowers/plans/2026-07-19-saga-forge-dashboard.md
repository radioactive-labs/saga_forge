# SagaForge Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `saga_forge-dashboard`, a mountable Rails engine gem that gives operators a read-mostly management dashboard over SagaForge (sagas index/show, event-ledger timeline, stalled/suspended views, per-class state-machine graph with per-instance overlay, and the four recovery actions).

**Architecture:** A `Rails::Engine` (`SagaForge::Dashboard`) living at `saga_forge-dashboard/` in the saga_forge monorepo, riding the core gem's `State`/`Event`/`Definition`/`Router` surface. Chassis (fail-closed auth, controller-served digest-busted assets, Tailwind v4, keyset pagination, turbo-morph refresh, release tooling) ported near-verbatim from `chrono_forge-dashboard`; saga-specific queries/presenters/pages/graph written fresh. Three small read-only additions land in the core gem first.

**Tech Stack:** Ruby >= 3.2, Rails engine (`railties`/`actionpack` >= 7.1), rides `saga_forge`. Tailwind v4 (`tailwindcss-ruby`), vendored Turbo + Cytoscape/dagre. Tests: Minitest + Combustion + rack-test.

**User Verification:** NO — no user verification required (verification is automated tests plus a `bin/dev` preview server the developer drives themselves).

**Spec:** `docs/superpowers/specs/2026-07-19-saga-forge-dashboard-design.md`.

**Reference (port source):** `/Users/stefan/Documents/plutonium/chrono_forge/chrono_forge-dashboard/`. When a task says "port chrono's X", copy that file and apply the **global rename table** below unless the task says otherwise.

**Global rename table (apply to every ported file):**
| chrono | saga_forge |
|---|---|
| `ChronoForge::Dashboard` | `SagaForge::Dashboard` |
| `chrono_forge/dashboard` (paths) | `saga_forge/dashboard` |
| `chrono_forge-dashboard` (gem/dir) | `saga_forge-dashboard` |
| `"ChronoForge"` (http_basic realm) | `"SagaForge"` |
| mount prefix `/chrono_forge` | `/saga_forge` |
| accent color (orange `#b34d08`) | indigo `#4650c8` (light) / `#97a0f5` (dark) |

**Commit policy note:** Stefan's global rule is "never stage or commit unless explicitly asked." Approving execution of this plan is that explicit ask for the commits named in each task's commit step. Core-gem commits (Task 1) go to `saga_forge` `main`; dashboard commits build up `saga_forge-dashboard/`. Push after each task.

**Locked implementation decisions (consistent across tasks):**
- Namespace: `SagaForge::Dashboard`; view/asset root `app/assets/saga_forge/dashboard`, `app/views/.../saga_forge/dashboard`.
- Route root: `sagas#index`. Instances are addressed by the `State` row PK (`params[:id]`), NOT correlation id (correlation ids are per-class and not globally unique; the PK is). The show page reads `saga_class` + `correlation_id` off the row.
- Saga-class discovery: `SagaForge::Router.saga_classes` enumerated live per request (never cached across reloads).
- `stay`/`transition_to` graph edges are best-effort (source-scanned); the graph legend says so.
- Vendored JS files reused verbatim from chrono: `turbo.min.js`, `cytoscape.min.js`, `dagre.min.js`, `cytoscape-dagre.js`. Chrono's `definition_graph.js` is adapted into `saga_graph.js` (Task 11). `dashboard.js` ported (Task 4).

---

## File structure

```
saga_forge/                                 # core gem (Task 1 only)
└── lib/saga_forge/definition.rb            # + to_graph, stay_targets
└── lib/saga_forge/state.rb                 # + compensating scope
└── lib/saga_forge/dashboard/graph.rb       # Graph/Node/Edge value objects (new file)

saga_forge/saga_forge-dashboard/            # the dashboard sub-gem
├── saga_forge-dashboard.gemspec
├── Gemfile
├── Rakefile
├── README.md
├── CHANGELOG.md
├── .standard.yml
├── config.ru                               # seed-and-preview server
├── bin/dev
├── lib/
│   ├── saga_forge/dashboard.rb             # module: config, asset_digest
│   └── saga_forge/dashboard/
│       ├── version.rb
│       ├── configuration.rb                # auth + display config
│       └── engine.rb
├── config/routes.rb
├── app/
│   ├── controllers/saga_forge/dashboard/
│   │   ├── base_controller.rb
│   │   ├── assets_controller.rb
│   │   ├── sagas_controller.rb
│   │   ├── overview_controller.rb
│   │   ├── stalled_controller.rb
│   │   ├── suspended_controller.rb
│   │   ├── definitions_controller.rb
│   │   └── actions_controller.rb
│   ├── queries/saga_forge/dashboard/
│   │   ├── sagas_query.rb
│   │   ├── stats_query.rb
│   │   └── overview_query.rb
│   ├── presenters/saga_forge/dashboard/
│   │   ├── timeline_presenter.rb
│   │   ├── context_presenter.rb
│   │   └── saga_graph.rb
│   ├── jobs/saga_forge/dashboard/bulk_recovery_job.rb
│   ├── helpers/saga_forge/dashboard/dashboard_helper.rb
│   ├── assets/saga_forge/dashboard/        # tailwind.css, dashboard.css, *.js
│   └── views/saga_forge/dashboard/         # pages + partials + layout
└── test/
    ├── test_helper.rb
    ├── internal/                            # combustion dummy app + sample sagas
    └── *_test.rb
```

---

### Task 0: Sub-gem scaffold, engine, configuration, test harness

**Goal:** A bootable `SagaForge::Dashboard` engine that mounts in a Combustion dummy app, with a passing smoke test.

**Files:**
- Create: `saga_forge-dashboard/saga_forge-dashboard.gemspec`, `Gemfile`, `Rakefile`, `.standard.yml`, `CHANGELOG.md`
- Create: `saga_forge-dashboard/lib/saga_forge/dashboard.rb`, `lib/saga_forge/dashboard/version.rb`, `lib/saga_forge/dashboard/configuration.rb`, `lib/saga_forge/dashboard/engine.rb`
- Create: `saga_forge-dashboard/config/routes.rb` (root + a placeholder)
- Create: `saga_forge-dashboard/app/controllers/saga_forge/dashboard/base_controller.rb`, `sagas_controller.rb` (stub `index` rendering "ok")
- Create: `saga_forge-dashboard/app/views/layouts/saga_forge/dashboard/application.html.erb` (minimal), `app/views/saga_forge/dashboard/sagas/index.html.erb`
- Create: `saga_forge-dashboard/test/test_helper.rb`, `test/internal/config/{routes.rb,database.yml}`, `test/internal/config/environments/test.rb`, `test/internal/db/schema.rb`, `test/internal/app/sagas/demo_saga.rb`
- Test: `saga_forge-dashboard/test/smoke_test.rb`

**Acceptance Criteria:**
- [ ] `cd saga_forge-dashboard && bundle install` succeeds against the path-dep core gem
- [ ] `bundle exec rake test` green; the smoke test GETs `/saga_forge` (mounted) and asserts 200
- [ ] `SagaForge::Dashboard.config` / `.configure` / `.reset_configuration!` work; `asset_digest` returns a 12-char hex (or VERSION on miss)
- [ ] `standardrb` clean

**Steps:**

- [ ] **Step 1: gemspec + Gemfile + Rakefile**

`saga_forge-dashboard/saga_forge-dashboard.gemspec`:
```ruby
require_relative "lib/saga_forge/dashboard/version"

Gem::Specification.new do |spec|
  spec.name = "saga_forge-dashboard"
  spec.version = SagaForge::Dashboard::VERSION
  spec.authors = ["Stefan Froelich"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.summary = "A management dashboard for SagaForge sagas."
  spec.description = "Mountable Rails engine: browse saga instances, read the event ledger, view state-machine graphs, and run recovery actions."
  spec.homepage = "https://github.com/radioactive-labs/saga_forge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/saga_forge-dashboard/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "saga_forge", ">= 0.1.0"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"
end
```

`saga_forge-dashboard/Gemfile`:
```ruby
source "https://rubygems.org"
gemspec

gem "saga_forge", path: ".."

gem "rake"
gem "minitest"
gem "minitest-reporters"
gem "combustion"
gem "rack-test"
gem "rails", ">= 7.1"
gem "sqlite3"
gem "standard"

group :development do
  gem "webrick"
  gem "tailwindcss-ruby", "~> 4.3"
end
```

`saga_forge-dashboard/Rakefile`:
```ruby
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

namespace :tailwind do
  desc "Compile the dashboard CSS from Tailwind source"
  task :build do
    require "tailwindcss/ruby"
    src = "app/assets/saga_forge/dashboard/tailwind.css"
    out = "app/assets/saga_forge/dashboard/dashboard.css"
    sh "#{Tailwindcss::Ruby.executable} -i #{src} -o #{out} --minify"
  end
end

# Never package stale CSS.
Rake::Task["build"].enhance(["tailwind:build"]) if Rake::Task.task_defined?("build")

require "standard/rake"
task default: %i[test standard]

Rake::Task["release"].clear if Rake::Task.task_defined?("release")
```

`.standard.yml`:
```yaml
ruby_version: 3.2
ignore:
  - "test/internal/**/*"
  - "config.ru"
```

`CHANGELOG.md`: a single `## [Unreleased]` heading.

- [ ] **Step 2: module + version + engine + configuration**

`lib/saga_forge/dashboard/version.rb`:
```ruby
module SagaForge
  module Dashboard
    VERSION = "0.1.0"
  end
end
```

`lib/saga_forge/dashboard/engine.rb`:
```ruby
require "rails/engine"

module SagaForge
  module Dashboard
    class Engine < ::Rails::Engine
      isolate_namespace SagaForge::Dashboard
    end
  end
end
```

`lib/saga_forge/dashboard.rb` — port chrono's `lib/chrono_forge/dashboard.rb` (read above), with renames, and DROP the `step_name_parser` require (SagaForge has no step-name grammar):
```ruby
require "saga_forge"
require "saga_forge/dashboard/version"
require "saga_forge/dashboard/configuration"
require "saga_forge/dashboard/engine"

module SagaForge
  module Dashboard
    ASSET_ROOT = "app/assets/saga_forge/dashboard"

    class << self
      def config = (@config ||= Configuration.new)

      def configure = yield(config)

      def reset_configuration! = @config = Configuration.new

      # Short content digest of a shipped asset, to cache-bust the served CSS/JS
      # despite the immutable cache header. Memoized once per boot.
      def asset_digest(file)
        @asset_digests ||= {}
        @asset_digests[file] ||= begin
          require "digest"
          Digest::SHA256.file(Engine.root.join(ASSET_ROOT, file)).hexdigest[0, 12]
        rescue
          VERSION
        end
      end
    end
  end
end
```

`lib/saga_forge/dashboard/configuration.rb` — port chrono's `configuration.rb` (read above) with renames. DROP `long_wait_threshold` (no wait-states page). Result:
```ruby
module SagaForge
  module Dashboard
    class AuthenticationNotConfigured < StandardError
      MESSAGE = <<~MSG.freeze
        SagaForge::Dashboard has no authentication configured. Do one of:
          - SagaForge::Dashboard.configure { |c| c.http_basic = { username:, password: } }
          - SagaForge::Dashboard.configure { |c| c.authenticate { |controller| ... } }
          - SagaForge::Dashboard.configure { |c| c.authentication = :none }  # then guard the mount yourself
      MSG
      def initialize(msg = MESSAGE) = super
    end

    class Configuration
      attr_accessor :http_basic, :authentication
      attr_reader :auth_hook
      attr_accessor :polling_interval, :polling_interval_options, :page_size

      def initialize
        @http_basic = nil
        @authentication = nil
        @auth_hook = nil
        @polling_interval = 15
        @polling_interval_options = [0, 5, 10, 15, 30, 60, 300]
        @page_size = 50
      end

      def authenticate(&block) = @auth_hook = block
    end
  end
end
```

- [ ] **Step 3: minimal routes + base controller + stub sagas controller + layout**

`config/routes.rb`:
```ruby
SagaForge::Dashboard::Engine.routes.draw do
  root to: "sagas#index"
  resources :sagas, only: %i[index show]
end
```

`app/controllers/saga_forge/dashboard/base_controller.rb` — port chrono's `base_controller.rb` (read above) with renames (`layout "saga_forge/dashboard/application"`, realm `"SagaForge"`).

`app/controllers/saga_forge/dashboard/sagas_controller.rb` (stub, fleshed out in Task 6):
```ruby
module SagaForge
  module Dashboard
    class SagasController < BaseController
      def index
        @saga_classes = SagaForge::Router.saga_classes
      end
    end
  end
end
```

`app/views/layouts/saga_forge/dashboard/application.html.erb` (minimal; full chrome in Task 4):
```erb
<!DOCTYPE html>
<html>
  <head>
    <title>SagaForge</title>
    <%= csrf_meta_tags %>
  </head>
  <body><%= yield %></body>
</html>
```

`app/views/saga_forge/dashboard/sagas/index.html.erb`:
```erb
<h1>Sagas</h1>
<ul><% @saga_classes.each do |k| %><li><%= k.name %></li><% end %></ul>
```

- [ ] **Step 4: test harness**

`test/internal/config/database.yml`:
```yaml
test:
  adapter: sqlite3
  database: db/test.sqlite3
  pool: 20
```

`test/internal/config/routes.rb`:
```ruby
Rails.application.routes.draw do
  mount SagaForge::Dashboard::Engine => "/saga_forge"
end
```

`test/internal/config/environments/test.rb`:
```ruby
Rails.application.configure do
  config.active_job.queue_adapter = :test
  config.secret_key_base = "test-secret"
  config.action_dispatch.cookies_serializer = :json
  config.action_controller.default_protect_from_forgery = false
end
```

`test/internal/db/schema.rb` — run SagaForge's migration so the two tables exist:
```ruby
require Gem.loaded_specs["saga_forge"].full_gem_path + "/lib/generators/saga_forge/templates/install_saga_forge"

ActiveRecord::Schema.define(version: 1) do
  # The gem's install template is a Migration subclass; run its change set.
  InstallSagaForge.new.change
end
```
(Wrinkle: if invoking the template class directly is awkward under Combustion, instead copy the two `create_table` blocks inline here. Verify the tables exist via the smoke test; report which approach you used.)

`test/internal/app/sagas/demo_saga.rb`:
```ruby
class DemoSaga < SagaForge::Base
  correlate_by :id
  start_with(:demo_started) { |saga, _| saga.context[:started] = true }
  during(:demo_waiting, on: :demo_done) { |saga, _| }
  finish_with :demo_complete
end
```

`test/test_helper.rb` — port chrono's dashboard test_helper structure:
```ruby
# frozen_string_literal: true
ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]

require "combustion"
require "action_controller/railtie"
require "saga_forge"

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job, :action_controller

require "saga_forge/dashboard"
require "rails/test_help"
require "rack/test"

Rails.application.eager_load!

module SagaForge
  module Dashboard
    class TestCase < ActiveSupport::TestCase
      include Rack::Test::Methods
      include ActiveJob::TestHelper

      def app = Rails.application

      setup do
        SagaForge.reset_configuration!
        SagaForge::Dashboard.reset_configuration!
        SagaForge::Dashboard.configure { |c| c.authentication = :none }
      end
    end
  end
end
```

`test/smoke_test.rb`:
```ruby
require "test_helper"

class SmokeTest < SagaForge::Dashboard::TestCase
  test "mounted root responds 200" do
    get "/saga_forge"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Sagas"
  end

  test "config round-trips and asset_digest shape" do
    SagaForge::Dashboard.configure { |c| c.page_size = 10 }
    assert_equal 10, SagaForge::Dashboard.config.page_size
    SagaForge::Dashboard.reset_configuration!
    assert_equal 50, SagaForge::Dashboard.config.page_size
  end
end
```

- [ ] **Step 5: run and commit**

Run: `cd saga_forge-dashboard && bundle install && bundle exec rake` → green.
```bash
git add saga_forge-dashboard
git commit -m "feat(dashboard): engine scaffold, config, combustion harness

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/saga_forge-dashboard.gemspec", "saga_forge-dashboard/lib/saga_forge/dashboard.rb", "saga_forge-dashboard/lib/saga_forge/dashboard/configuration.rb", "saga_forge-dashboard/test/test_helper.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake", "acceptanceCriteria": ["bundle install", "smoke test 200 at mount", "config round-trips", "standard clean"], "requiresUserVerification": false}
```

---

### Task 1: Core-gem additions — Definition#to_graph, stay_targets, State.compensating

**Goal:** Add the structured graph DTO and the `compensating` scope to the CORE `saga_forge` gem, fully tested in its own suite.

**Files:**
- Create: `saga_forge/lib/saga_forge/dashboard/graph.rb` (value objects — namespaced under `SagaForge::Dashboard` so the DTO has a home even though the dashboard is a separate gem; the core gem owns the shape)
- Modify: `saga_forge/lib/saga_forge/definition.rb` (add `to_graph`, `stay_targets`)
- Modify: `saga_forge/lib/saga_forge/state.rb` (add `compensating` scope)
- Test: `saga_forge/test/definition_graph_test.rb`, extend `saga_forge/test/models_test.rb`

**Acceptance Criteria:**
- [ ] `OrderSaga.definition.to_graph` returns a `SagaForge::Dashboard::Graph` with nodes (start + during states + terminals, each `{id,label,kind}`) and typed edges (`:chain` with event labels, `:jump`, `:stay`)
- [ ] Chain edges are complete and correctly labeled; jump edges match `jump_targets`; a `stay`-looping handler yields a `:stay` self-loop
- [ ] `stay_targets` mirrors `jump_targets` (best-effort literal `saga.stay` / `stay` scan within each handler's block extent), returns `[state_sym, ...]` (states whose handler can stay)
- [ ] `State.compensating` scope returns rows with `current_state == "compensating"`
- [ ] Graph objects are frozen (immutable like `Definition`)

**Steps:**

- [ ] **Step 1: Graph value objects**

`saga_forge/lib/saga_forge/dashboard/graph.rb`:
```ruby
module SagaForge
  module Dashboard
    # Structured, serializable graph derived from a compiled Definition. The
    # core gem owns this shape so any consumer (the dashboard, a doc generator)
    # gets the same typed representation instead of parsing the mermaid string.
    Graph = Struct.new(:nodes, :edges) do
      def to_h = {nodes: nodes.map(&:to_h), edges: edges.map(&:to_h)}
    end

    # kind: :start | :state | :terminal
    Node = Struct.new(:id, :label, :kind, keyword_init: true) do
      def to_h = {id: id, label: label, kind: kind}
    end

    # kind: :chain (complete) | :jump (best-effort) | :stay (best-effort self-loop)
    Edge = Struct.new(:from, :to, :kind, :label, keyword_init: true) do
      def to_h = {from: from, to: to, kind: kind, label: label}
    end
  end
end
```
(This file lives in the CORE gem under `lib/saga_forge/dashboard/`. Zeitwerk maps it to `SagaForge::Dashboard::Graph`. The dashboard GEM reopens `SagaForge::Dashboard` as a module; no conflict — Ruby modules are open, and the core gem only defines the three Structs here.)

- [ ] **Step 2: stay_targets + to_graph on Definition**

Read the existing `jump_targets` in `saga_forge/lib/saga_forge/definition.rb` to mirror its exact block-extent scanning machinery. Add `stay_targets` right after it, then `to_graph`:
```ruby
# Best-effort literal scan for `stay` / `saga.stay` inside each handler block's
# exact extent (same machinery as jump_targets). Returns the set of states
# whose handler can loop. Computed/conditional stays the scan can't see are
# omitted, matching jump_targets' honesty.
def stay_targets
  scan_handlers(/(?:^|[^.\w])(?:saga\.)?stay\b/).map { |(from, _match)| from }.uniq
end

# Structured graph (chain + jump + stay), the sibling of to_mermaid.
def to_graph
  nodes = [SagaForge::Dashboard::Node.new(id: START.to_s, label: "start", kind: :start)]
  (@states - @terminal_states).each do |s|
    nodes << SagaForge::Dashboard::Node.new(id: s.to_s, label: s.to_s, kind: :state)
  end
  @terminal_states.each do |s|
    nodes << SagaForge::Dashboard::Node.new(id: s.to_s, label: s.to_s, kind: :terminal)
  end

  edges = []
  chain = [START] + (@states - @terminal_states) + [@terminal_states.first]
  chain.each_cons(2) do |from, to|
    label = (from == START) ? @start_event.to_s : events_for_state(from).join(" / ")
    edges << SagaForge::Dashboard::Edge.new(from: from.to_s, to: to.to_s, kind: :chain, label: label)
  end
  jump_targets.each do |(from, to)|
    edges << SagaForge::Dashboard::Edge.new(from: from.to_s, to: to.to_s, kind: :jump, label: "jump")
  end
  stay_targets.each do |state|
    edges << SagaForge::Dashboard::Edge.new(from: state.to_s, to: state.to_s, kind: :stay, label: "stay")
  end

  SagaForge::Dashboard::Graph.new(nodes.freeze, edges.freeze).freeze
end
```
(Wrinkle: `jump_targets` currently returns `[[from_state, to_sym], ...]` where `from` may be the `[*]`/START display form. Inspect its actual return shape and normalize: `to_graph` needs real state ids, not display strings. If `jump_targets` emits `"[*]"` for START, map it to `START.to_s`. Factor the shared block-extent scanner into a private `scan_handlers(regex)` that both `jump_targets` and `stay_targets` call, if it isn't already factored — refactor `jump_targets` to use it and keep its tests green.)

- [ ] **Step 3: compensating scope**

In `saga_forge/lib/saga_forge/state.rb`, next to the `stalled`/`suspended` scopes:
```ruby
scope :compensating, -> { where(current_state: COMPENSATING.to_s) }
```

- [ ] **Step 4: tests**

`saga_forge/test/definition_graph_test.rb`:
```ruby
require "test_helper"

class DefinitionGraphTest < SagaForge::TestCase
  test "to_graph nodes: start, during states, terminals" do
    g = OrderSaga.definition.to_graph
    kinds = g.nodes.group_by(&:kind).transform_values { |ns| ns.map(&:id) }
    assert_equal ["__start__"], kinds[:start]
    assert_includes kinds[:state], "awaiting_settlement"
    assert_includes kinds[:terminal], "completed"
  end

  test "chain edges are complete and labeled by event" do
    g = OrderSaga.definition.to_graph
    chain = g.edges.select { |e| e.kind == :chain }
    pairs = chain.map { |e| [e.from, e.to] }
    assert_includes pairs, ["__start__", "awaiting_settlement"]
    assert_includes pairs, ["awaiting_settlement", "awaiting_review"]
    settle = chain.find { |e| e.from == "awaiting_settlement" }
    assert_includes settle.label, "payment_settled"
  end

  test "jump edges match jump_targets" do
    g = OrderSaga.definition.to_graph
    jumps = g.edges.select { |e| e.kind == :jump }.map { |e| [e.from, e.to] }
    # OrderSaga's review_passed handler does `transition_to :completed`
    assert_includes jumps, ["awaiting_review", "completed"]
  end

  test "stay self-loop detected" do
    # StaySaga (existing fixture) loops in :counting on :tick
    g = StaySaga.definition.to_graph
    stays = g.edges.select { |e| e.kind == :stay }.map { |e| [e.from, e.to] }
    assert_includes stays, ["counting", "counting"]
  end

  test "graph and members are frozen and serialize to_h" do
    g = OrderSaga.definition.to_graph
    assert g.frozen?
    h = g.to_h
    assert h[:nodes].first.key?(:kind)
    assert h[:edges].first.key?(:label)
  end
end
```

Extend `saga_forge/test/models_test.rb` with:
```ruby
test "compensating scope" do
  SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "compensating")
  SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "awaiting")
  assert_equal ["c1"], SagaForge::State.compensating.pluck(:correlation_id)
end
```

- [ ] **Step 5: run and commit (CORE gem)**

Run: `cd saga_forge && bundle exec rake` → green (existing 128 tests + new).
```bash
git add lib/saga_forge/dashboard/graph.rb lib/saga_forge/definition.rb lib/saga_forge/state.rb test/definition_graph_test.rb test/models_test.rb
git commit -m "feat: Definition#to_graph, stay_targets, State.compensating (dashboard reads)

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["lib/saga_forge/dashboard/graph.rb", "lib/saga_forge/definition.rb", "lib/saga_forge/state.rb"], "verifyCommand": "cd /Users/stefan/Documents/plutonium/saga_forge && bundle exec rake test TEST=test/definition_graph_test.rb", "acceptanceCriteria": ["to_graph typed edges", "stay self-loop", "jump matches jump_targets", "compensating scope", "frozen graph"], "requiresUserVerification": false}
```

---

### Task 2: Auth chassis + assets chassis

**Goal:** Fail-closed auth on every page and controller-served, digest-busted static assets.

**Files:**
- Modify: `app/controllers/saga_forge/dashboard/base_controller.rb` (already ported in Task 0 — verify)
- Create: `app/controllers/saga_forge/dashboard/assets_controller.rb`
- Modify: `config/routes.rb` (add the assets route with the allowlist constraint)
- Create: `app/assets/saga_forge/dashboard/` vendored JS (copy from chrono verbatim: `turbo.min.js`, `cytoscape.min.js`, `dagre.min.js`, `cytoscape-dagre.js`), `dashboard.js` (ported, Task 4 fleshes its behaviors — copy chrono's now), a placeholder `dashboard.css` and `tailwind.css`
- Test: `test/auth_test.rb`, `test/assets_test.rb`

**Acceptance Criteria:**
- [ ] With no auth configured, any page raises `AuthenticationNotConfigured` (fail-closed)
- [ ] `http_basic` mode challenges then accepts correct creds (constant-time); `authenticate` block mode runs in controller context; `:none` allows
- [ ] `GET /saga_forge/assets/dashboard.css` returns 200 with `Cache-Control: ...immutable` and the css MIME type; an unlisted file 404s at the route
- [ ] `AssetsController` skips auth (assets load even when a page would challenge)

**Steps:**

- [ ] **Step 1: assets controller** — port chrono's `assets_controller.rb` (read above) with renames. TYPES drops `definition_graph.js`, adds `saga_graph.js`:
```ruby
module SagaForge
  module Dashboard
    class AssetsController < BaseController
      skip_before_action :authenticate!
      skip_forgery_protection

      TYPES = {
        "dashboard.css" => "text/css",
        "dashboard.js" => "application/javascript",
        "turbo.min.js" => "application/javascript",
        "cytoscape.min.js" => "application/javascript",
        "dagre.min.js" => "application/javascript",
        "cytoscape-dagre.js" => "application/javascript",
        "saga_graph.js" => "application/javascript"
      }.freeze
      ROOT = SagaForge::Dashboard::Engine.root.join("app/assets/saga_forge/dashboard")

      def show
        file = params[:file]
        type = TYPES[file] or return head(:not_found)
        path = ROOT.join(file)
        return head(:not_found) unless path.file?

        response.set_header("Cache-Control", "public, max-age=31536000, immutable")
        send_file path, type: type, disposition: "inline"
      end
    end
  end
end
```

- [ ] **Step 2: assets route** — append to `config/routes.rb` inside the draw block:
```ruby
  get "assets/:file", to: "assets#show", constraints: {
    file: /(dashboard\.(css|js)|turbo\.min\.js|cytoscape\.min\.js|dagre\.min\.js|cytoscape-dagre\.js|saga_graph\.js)/
  }
```

- [ ] **Step 3: vendored assets** — copy verbatim from `chrono_forge-dashboard/app/assets/chrono_forge/dashboard/`: `turbo.min.js`, `cytoscape.min.js`, `dagre.min.js`, `cytoscape-dagre.js`, and `dashboard.js` (rename internal `cf-`/`chrono_forge` cookie/data keys to `sf-`/`saga_forge`; keep behavior). Create a minimal `tailwind.css` (`@import "tailwindcss";`) and run `rake tailwind:build` to produce `dashboard.css` (Task 4 writes the real styles; a compiled stub is fine now).

- [ ] **Step 4: tests** — port chrono's `test/auth_test.rb` and `test/assets_test.rb` structure with renames. Minimum:
```ruby
# test/auth_test.rb
require "test_helper"
class AuthTest < SagaForge::Dashboard::TestCase
  test "unconfigured auth raises fail-closed" do
    SagaForge::Dashboard.reset_configuration! # clear the :none from setup
    assert_raises(SagaForge::Dashboard::AuthenticationNotConfigured) { get "/saga_forge" }
  end

  test "http_basic challenges then accepts" do
    SagaForge::Dashboard.reset_configuration!
    SagaForge::Dashboard.configure { |c| c.http_basic = {username: "a", password: "b"} }
    get "/saga_forge"
    assert_equal 401, last_response.status
    authorize "a", "b"
    get "/saga_forge"
    assert_equal 200, last_response.status
  end

  test "authenticate block runs in controller context" do
    SagaForge::Dashboard.reset_configuration!
    SagaForge::Dashboard.configure { |c| c.authenticate { |ctrl| ctrl.head(:forbidden) unless ctrl.request.get_header("HTTP_X_OK") } }
    get "/saga_forge"
    assert_equal 403, last_response.status
    get "/saga_forge", {}, {"HTTP_X_OK" => "1"}
    assert_equal 200, last_response.status
  end
end
```
```ruby
# test/assets_test.rb
require "test_helper"
class AssetsTest < SagaForge::Dashboard::TestCase
  test "serves css with immutable cache header, skips auth" do
    SagaForge::Dashboard.reset_configuration! # even with no auth, assets serve
    SagaForge::Dashboard.configure { |c| c.http_basic = {username: "a", password: "b"} }
    get "/saga_forge/assets/dashboard.css"
    assert_equal 200, last_response.status
    assert_match "text/css", last_response.headers["Content-Type"]
    assert_match "immutable", last_response.headers["Cache-Control"]
  end

  test "unlisted asset 404s at the route" do
    get "/saga_forge/assets/secrets.rb"
    assert_equal 404, last_response.status
  end
end
```

- [ ] **Step 5: run and commit**

```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): fail-closed auth and controller-served digest-busted assets

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/controllers/saga_forge/dashboard/assets_controller.rb", "saga_forge-dashboard/config/routes.rb", "saga_forge-dashboard/test/auth_test.rb", "saga_forge-dashboard/test/assets_test.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/auth_test.rb TEST=test/assets_test.rb", "acceptanceCriteria": ["fail-closed", "three auth modes", "immutable assets", "route allowlist 404"], "requiresUserVerification": false}
```

---

### Task 3: Layout, helper, Tailwind styles, poll-refresh chrome

**Goal:** The shared layout (header nav, poll region, flash, time toggle), `DashboardHelper`, and the real compiled Tailwind CSS.

**Files:**
- Modify: `app/views/layouts/saga_forge/dashboard/application.html.erb` (full chrome)
- Create: `app/helpers/saga_forge/dashboard/dashboard_helper.rb`
- Modify: `app/assets/saga_forge/dashboard/tailwind.css` (real styles), rebuild `dashboard.css`
- Modify: `app/assets/saga_forge/dashboard/dashboard.js` (poll region + confirm delegation + time toggle — from chrono, confirm behaviors)
- Test: `test/dashboard_helper_test.rb`

**Acceptance Criteria:**
- [ ] Layout renders nav (Sagas / Overview / Stalled / Suspended), the interval `<select>`, the relative/absolute time toggle, a flash-toast region, and `<main data-poll-region>`; loads `dashboard.css` + `turbo.min.js` in `<head>` and `dashboard.js` at body end, all with `?v=<digest>`
- [ ] `DashboardHelper` exposes: `state_badge(state)`, `status_badge(event_status)`, `time_tag(t)` (relative/absolute), `bar_width_class(pct)` (CSP-safe `sf-bar-{0..100}`), `format_bytes`, `poll_interval`
- [ ] `bundle exec rake tailwind:build` produces a `dashboard.css` that includes the `sf-bar-*` and badge classes
- [ ] Indigo accent, light+dark via `prefers-color-scheme` and a `data-theme` toggle

**Steps:**

- [ ] **Step 1: layout** — port chrono's `app/views/layouts/chrono_forge/dashboard/application.html.erb` with renames. Nav links: `sagas_path` (Sagas), `overview_path` (Overview), `stalled_path` (Stalled), `suspended_path` (Suspended). Use `request.script_name` + `asset_digest` for asset URLs exactly as chrono does. Set `data-poll-interval` from the `sf_poll_interval` cookie (default `config.polling_interval`). Wrap main content in `<main id="sf-poll-region" data-poll-region>`. Honor `@sf_disable_polling`.

- [ ] **Step 2: helper** — port the relevant slice of chrono's `dashboard_helper.rb` (drop workflow-specific helpers). Concretely:
```ruby
module SagaForge
  module Dashboard
    module DashboardHelper
      STATE_COLORS = {
        "compensating" => "amber", "compensated" => "slate",
        "cancelled" => "slate"
      }.freeze

      def state_badge(state)
        color = STATE_COLORS[state.to_s] || (terminal_like?(state) ? "green" : "indigo")
        content_tag(:span, state, class: "sf-badge sf-badge-#{color}")
      end

      def status_badge(status)
        color = {"pending" => "slate", "processed" => "green", "stalled" => "amber", "failed" => "red"}[status.to_s] || "slate"
        content_tag(:span, status, class: "sf-badge sf-badge-#{color}")
      end

      def terminal_like?(state) = %w[completed done finished shipped notified].include?(state.to_s)

      def bar_width_class(pct) = "sf-bar-#{pct.to_i.clamp(0, 100)}"

      def format_bytes(n)
        return "0 B" if n.to_i.zero?
        units = %w[B KB MB]
        e = [(Math.log(n, 1024)).floor, units.size - 1].min
        "#{(n.to_f / (1024**e)).round(1)} #{units[e]}"
      end

      def poll_interval
        cookies[:sf_poll_interval].presence&.to_i || SagaForge::Dashboard.config.polling_interval
      end

      def time_tag(t)
        return "" unless t
        content_tag(:time, t.iso8601, datetime: t.iso8601, class: "sf-time",
          title: t.utc.strftime("%Y-%m-%d %H:%M:%S UTC"), data: {ts: t.to_i})
      end
    end
  end
end
```
(The `sf-time` element's relative/absolute rendering is done client-side by `dashboard.js`, ported from chrono.)

- [ ] **Step 3: tailwind styles** — port chrono's `tailwind.css`, swapping the accent to indigo and adding the `sf-badge-{indigo,green,amber,red,slate}`, `sf-bar-{0..100}` (generated), and layout classes. Run `bundle exec rake tailwind:build`.

- [ ] **Step 4: dashboard.js** — ensure the ported `dashboard.js` handles: the poll-region morph refresh on the cookie interval (skipped when `data-poll-region` absent), the `data-confirm` submit delegation (`window.confirm`), the relative/absolute `sf-time` rendering + toggle, and the interval `<select>` writing the `sf_poll_interval` cookie. Rename all `cf-`/`chrono` identifiers to `sf-`/`saga`.

- [ ] **Step 5: helper test**
```ruby
require "test_helper"
class DashboardHelperTest < SagaForge::Dashboard::TestCase
  include SagaForge::Dashboard::DashboardHelper
  def cookies = {}
  test "bar width clamps" do
    assert_equal "sf-bar-100", bar_width_class(150)
    assert_equal "sf-bar-0", bar_width_class(-5)
  end
  test "status badge colors" do
    assert_match "sf-badge-red", status_badge("failed")
    assert_match "sf-badge-green", status_badge("processed")
  end
  test "format bytes" do
    assert_equal "1.0 KB", format_bytes(1024)
  end
end
```

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake tailwind:build && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): layout chrome, view helpers, tailwind styles, poll refresh

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/views/layouts/saga_forge/dashboard/application.html.erb", "saga_forge-dashboard/app/helpers/saga_forge/dashboard/dashboard_helper.rb", "saga_forge-dashboard/app/assets/saga_forge/dashboard/tailwind.css"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake", "acceptanceCriteria": ["layout chrome + asset digests", "helper badges/bar/bytes", "tailwind builds sf-* classes", "indigo light/dark"], "requiresUserVerification": false}
```

---

### Task 4: SagasQuery + StatsQuery, sagas#index page

**Goal:** The class-scoped, keyset-paginated, filterable saga list with capped state counts.

**Files:**
- Create: `app/queries/saga_forge/dashboard/sagas_query.rb`, `stats_query.rb`
- Modify: `app/controllers/saga_forge/dashboard/sagas_controller.rb` (real `index`)
- Create: `app/views/saga_forge/dashboard/sagas/index.html.erb`, `_stats.html.erb`, `_filters.html.erb`, `_saga_row.html.erb`
- Test: `test/sagas_query_test.rb`, `test/stats_query_test.rb`, `test/sagas_index_test.rb`

**Acceptance Criteria:**
- [ ] `SagasQuery` keyset-paginates `State.for_saga(klass)` by PK, `per+1` look-ahead, no COUNT/OFFSET; virtual filters `stalled`/`suspended`/`compensating` compose the derived scopes; a plain `current_state` filter works; `correlation_id` prefix search is `sanitize_sql_like`-escaped
- [ ] `StatsQuery` returns capped counts per state (`CAP`), rendering `"CAP+"` when saturated
- [ ] `sagas#index` requires a `?class=` (defaults to the first registered saga class), shows filter chips with counts, a keyset Newer/Older nav, and a prefix search box
- [ ] Row links target the show page by State PK

**Steps:**

- [ ] **Step 1: SagasQuery** (adapt chrono's `WorkflowsQuery` keyset pattern):
```ruby
module SagaForge
  module Dashboard
    # Keyset pagination over one saga class's State rows. Orders by PK desc,
    # pages with id < / > cursor, never COUNTs. Virtual filters compose the
    # engine's derived scopes (stalled/suspended/compensating).
    class SagasQuery
      DEFAULT_PER = 50
      MAX_PER = 200

      def initialize(saga_class:, filter: nil, correlation: nil, before: nil, after: nil, per: DEFAULT_PER)
        @saga_class = saga_class
        @filter = filter.presence
        @correlation = correlation.presence
        @before = before.presence&.to_i
        @after = after.presence&.to_i
        @per = per.to_i.clamp(1, MAX_PER)
      end

      def records
        load
        @records
      end
      attr_reader :per
      def has_next? = (load; @has_next)
      def has_prev? = (load; @has_prev)
      def next_cursor = records.last&.id
      def prev_cursor = records.first&.id

      private

      def base
        SagaForge::State.for_saga(@saga_class)
      end

      def filtered
        s = base
        case @filter
        when "stalled" then s = s.where(id: SagaForge::Event.stalled.select(:saga_forge_state_id))
        when "suspended" then s = s.where(id: SagaForge::Event.failed.select(:saga_forge_state_id))
        when "compensating" then s = s.where(current_state: "compensating")
        when nil, "", "all" then s
        else s = s.where(current_state: @filter)
        end
        if @correlation
          s = s.where("correlation_id LIKE ?", "#{SagaForge::State.sanitize_sql_like(@correlation)}%")
        end
        s
      end

      def load
        return if @loaded
        @loaded = true
        col = "#{SagaForge::State.table_name}.id"
        if @after
          rows = filtered.where("#{col} > ?", @after).order(id: :asc).limit(@per + 1).to_a
          @has_prev = rows.size > @per
          @records = rows.first(@per).reverse
          @has_next = true
        else
          scope = filtered
          scope = scope.where("#{col} < ?", @before) if @before
          rows = scope.order(id: :desc).limit(@per + 1).to_a
          @has_next = rows.size > @per
          @records = rows.first(@per)
          @has_prev = @before.present?
        end
      end
    end
  end
end
```

- [ ] **Step 2: StatsQuery** (capped index-only counts):
```ruby
module SagaForge
  module Dashboard
    class StatsQuery
      CAP = 5000

      def initialize(saga_class:)
        @saga_class = saga_class
      end

      def counts
        base = SagaForge::State.for_saga(@saga_class)
        {
          all: capped(base),
          stalled: capped(base.where(id: SagaForge::Event.stalled.select(:saga_forge_state_id))),
          suspended: capped(base.where(id: SagaForge::Event.failed.select(:saga_forge_state_id))),
          compensating: capped(base.where(current_state: "compensating"))
        }
      end

      def label(n) = (n >= CAP) ? "#{CAP}+" : n.to_s

      private

      def capped(relation)
        SagaForge::State.from(relation.select(:id).limit(CAP), :capped).count
      end
    end
  end
end
```

- [ ] **Step 3: controller**
```ruby
module SagaForge
  module Dashboard
    class SagasController < BaseController
      def index
        @saga_classes = SagaForge::Router.saga_classes.sort_by(&:name)
        @saga_class = (params[:class].presence && @saga_classes.find { |k| k.name == params[:class] }) || @saga_classes.first
        return render :empty unless @saga_class

        @stats = StatsQuery.new(saga_class: @saga_class)
        @query = SagasQuery.new(saga_class: @saga_class, filter: params[:filter],
          correlation: params[:q], before: params[:before], after: params[:after],
          per: SagaForge::Dashboard.config.page_size)
      end

      def show
        @state = SagaForge::State.find(params[:id])
        # fleshed out in Task 6
      end
    end
  end
end
```
Add `app/views/saga_forge/dashboard/sagas/empty.html.erb` ("No saga classes are registered.").

- [ ] **Step 4: views** — `index.html.erb` renders a class `<select>` (submits `?class=`), `_stats` (filter chips using `@stats.counts`/`label`), `_filters` (the prefix search), the `_saga_row` collection, and Newer/Older links using `prev_cursor`/`next_cursor` + `has_prev?`/`has_next?`. `_saga_row` shows correlation_id (link to `saga_path(row)`), `state_badge(row.current_state)`, version, `time_tag(row.updated_at)`.

- [ ] **Step 5: tests**
```ruby
# test/sagas_query_test.rb
require "test_helper"
class SagasQueryTest < SagaForge::Dashboard::TestCase
  def mk(corr, state: "demo_waiting") = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: corr, current_state: state)

  test "keyset paginates by pk desc without count" do
    5.times { |i| mk("c#{i}") }
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, per: 2)
    assert_equal 2, q.records.size
    assert q.has_next?
    q2 = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, per: 2, before: q.next_cursor)
    assert_equal 2, q2.records.size
    refute_equal q.records.map(&:id), q2.records.map(&:id)
  end

  test "stalled filter composes the derived scope" do
    s = mk("s1")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "s1",
      event_name: "x", status: :stalled, state: s)
    mk("s2")
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, filter: "stalled")
    assert_equal ["s1"], q.records.map(&:correlation_id)
  end

  test "correlation prefix search escapes like wildcards" do
    mk("abc"); mk("axx")
    q = SagaForge::Dashboard::SagasQuery.new(saga_class: DemoSaga, correlation: "ab")
    assert_equal ["abc"], q.records.map(&:correlation_id)
  end
end
```
```ruby
# test/stats_query_test.rb
require "test_helper"
class StatsQueryTest < SagaForge::Dashboard::TestCase
  test "counts by derived scope" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "c1", event_name: "x", status: :failed, state: s)
    counts = SagaForge::Dashboard::StatsQuery.new(saga_class: DemoSaga).counts
    assert_equal 1, counts[:all]
    assert_equal 1, counts[:suspended]
    assert_equal 0, counts[:stalled]
  end
end
```
```ruby
# test/sagas_index_test.rb
require "test_helper"
class SagasIndexTest < SagaForge::Dashboard::TestCase
  test "index renders rows for the selected class" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "shown", current_state: "demo_waiting")
    get "/saga_forge/sagas", {class: "DemoSaga"}
    assert_equal 200, last_response.status
    assert_includes last_response.body, "shown"
  end
end
```

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): sagas index with keyset query and capped stats

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/queries/saga_forge/dashboard/sagas_query.rb", "saga_forge-dashboard/app/queries/saga_forge/dashboard/stats_query.rb", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/sagas_controller.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/sagas_query_test.rb TEST=test/stats_query_test.rb TEST=test/sagas_index_test.rb", "acceptanceCriteria": ["keyset no-COUNT", "derived-scope filters", "prefix search escaped", "capped counts", "index renders"], "requiresUserVerification": false}
```

---

### Task 5: TimelinePresenter + ContextPresenter, sagas#show page

**Goal:** The saga detail page: merged event+compensation timeline, context tree, summary banner with health callouts. (Action buttons wired in Task 8.)

**Files:**
- Create: `app/presenters/saga_forge/dashboard/timeline_presenter.rb`, `context_presenter.rb`
- Modify: `app/controllers/saga_forge/dashboard/sagas_controller.rb` (`show`)
- Create: `app/views/saga_forge/dashboard/sagas/show.html.erb`, `_summary.html.erb`, `_timeline.html.erb`, `_compensation.html.erb`, `_context_tree.html.erb`
- Test: `test/timeline_presenter_test.rb`, `test/context_presenter_test.rb`, `test/sagas_show_test.rb`

**Acceptance Criteria:**
- [ ] `TimelinePresenter` returns chronological `Entry` structs merging `state.history` (each event: name, status, attempts, stall_count, error) with compensation progress from `context["__saga_forge"]` (compensated LIFO list, comp_attempts, comp_error), ordered by the events' `created_at`
- [ ] `ContextPresenter` renders the user context as typed key nodes (type + byte size) and surfaces the reserved `__saga_forge` sub-hash separately
- [ ] `show` health flags: stalled (has stalled event), suspended (has failed event), stuck-compensating (`comp_error` present); each renders a callout
- [ ] Failed events show their `error` class/message with the traceback collapsible

**Steps:**

- [ ] **Step 1: TimelinePresenter**
```ruby
module SagaForge
  module Dashboard
    # One chronological stream for a saga instance: the event ledger merged with
    # the compensation progress the engine records in context["__saga_forge"].
    # The engine does not pre-merge these, so the dashboard owns it.
    class TimelinePresenter
      Entry = Struct.new(:at, :kind, :label, :status, :detail, keyword_init: true)

      def initialize(state)
        @state = state
      end

      def entries
        rows = @state.history.map do |e|
          Entry.new(at: e.created_at, kind: :event, label: e.event_name, status: e.status,
            detail: {payload: e.payload, attempts: e.attempts, stall_count: e.stall_count,
                     retry_budgets: e.retry_budgets, error: e.error})
        end
        rows + compensation_entries
      end

      def sorted = entries.sort_by { |e| [e.at || Time.at(0), e.kind == :event ? 0 : 1] }

      private

      def meta = @state.context["__saga_forge"] || {}

      def compensation_entries
        done = meta["compensated"] || []
        list = done.map do |name|
          Entry.new(at: @state.updated_at, kind: :compensation, label: name, status: "processed",
            detail: {attempts: meta.dig("comp_attempts", name)})
        end
        if (err = meta["comp_error"])
          list << Entry.new(at: @state.updated_at, kind: :compensation, label: err["name"], status: "failed",
            detail: {error: err})
        end
        list
      end
    end
  end
end
```
(Note the honest limitation, documented in the spec §7: compensation entries lack per-step timestamps, so they sort to the end of same-`updated_at` groups. State it in a code comment.)

- [ ] **Step 2: ContextPresenter**
```ruby
module SagaForge
  module Dashboard
    class ContextPresenter
      Node = Struct.new(:key, :type, :bytes, :preview, keyword_init: true)

      def initialize(state)
        @context = state.context || {}
      end

      def user_nodes
        @context.reject { |k, _| k == "__saga_forge" }.map { |k, v| node(k, v) }
      end

      def saga_meta = @context["__saga_forge"] # nil or the reserved sub-hash

      private

      def node(key, value)
        json = value.to_json
        Node.new(key: key, type: ruby_type(value), bytes: json.bytesize, preview: json.truncate(200))
      end

      def ruby_type(v)
        case v
        when Hash then "object" when Array then "array" when Numeric then "number"
        when TrueClass, FalseClass then "boolean" when NilClass then "null" else "string" end
      end
    end
  end
end
```

- [ ] **Step 3: controller show**
```ruby
def show
  @state = SagaForge::State.find(params[:id])
  @timeline = TimelinePresenter.new(@state)
  @context = ContextPresenter.new(@state)
  @stalled = @state.events.stalled.exists?
  @suspended = @state.events.failed.exists?
  @comp_error = @state.context.dig("__saga_forge", "comp_error")
end
```

- [ ] **Step 4: views** — `show.html.erb` composes `_summary` (state badge + callouts using `@stalled`/`@suspended`/`@comp_error`, plus a link to `saga_definition_path(@state, correlation_id: @state.correlation_id)`), `_timeline` (renders `@timeline.sorted`, each entry with `status_badge`, `time_tag`, collapsible detail; failed events show `error["class"]`/`error["message"]` and a `<details>` traceback), `_compensation` (rendered when `@state.context["__saga_forge"]` present: the LIFO `compensated` list, `comp_attempts`, `comp_error`), `_context_tree` (`@context.user_nodes` + a separate `@context.saga_meta` section).

- [ ] **Step 5: tests**
```ruby
# test/timeline_presenter_test.rb
require "test_helper"
class TimelinePresenterTest < SagaForge::Dashboard::TestCase
  test "merges events and compensation progress" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "compensated",
      context: {"__saga_forge" => {"compensated" => ["undo_a"], "comp_attempts" => {"undo_a" => 1}}})
    SagaForge::Event.create!(event_id: "e1", saga_class: "DemoSaga", correlation_id: "c1",
      event_name: "demo_started", status: :processed, state: s, created_at: 2.minutes.ago)
    entries = SagaForge::Dashboard::TimelinePresenter.new(s).sorted
    kinds = entries.map(&:kind)
    assert_includes kinds, :event
    assert_includes kinds, :compensation
    comp = entries.find { |e| e.kind == :compensation }
    assert_equal "undo_a", comp.label
  end
end
```
```ruby
# test/context_presenter_test.rb
require "test_helper"
class ContextPresenterTest < SagaForge::Dashboard::TestCase
  test "separates user keys from engine meta" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "x",
      context: {"total" => 5, "__saga_forge" => {"target" => "compensated"}})
    p = SagaForge::Dashboard::ContextPresenter.new(s)
    assert_equal ["total"], p.user_nodes.map(&:key)
    assert_equal "compensated", p.saga_meta["target"]
    assert_equal "number", p.user_nodes.first.type
  end
end
```
```ruby
# test/sagas_show_test.rb
require "test_helper"
class SagasShowTest < SagaForge::Dashboard::TestCase
  test "show renders timeline and flags suspended" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "c1",
      event_name: "demo_done", status: :failed, state: s, error: {"class" => "Boom", "message" => "nope"})
    get "/saga_forge/sagas/#{s.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "demo_done"
    assert_includes last_response.body, "Boom"
  end
end
```

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): saga show with merged timeline and context tree

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/presenters/saga_forge/dashboard/timeline_presenter.rb", "saga_forge-dashboard/app/presenters/saga_forge/dashboard/context_presenter.rb", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/sagas_controller.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/timeline_presenter_test.rb TEST=test/context_presenter_test.rb TEST=test/sagas_show_test.rb", "acceptanceCriteria": ["merged timeline", "context split", "health flags", "failed error+traceback"], "requiresUserVerification": false}
```

---

### Task 6: Overview, stalled, suspended pages

**Goal:** The fleet overview (class × state) and the two triage lists.

**Files:**
- Create: `app/queries/saga_forge/dashboard/overview_query.rb`
- Create: `app/controllers/saga_forge/dashboard/overview_controller.rb`, `stalled_controller.rb`, `suspended_controller.rb`
- Modify: `config/routes.rb`
- Create: views for overview (frame shell + `classes` frame + stat cards), stalled/index, suspended/index
- Test: `test/overview_query_test.rb`, `test/overview_test.rb`, `test/stalled_test.rb`, `test/suspended_test.rb`

**Acceptance Criteria:**
- [ ] `OverviewQuery` uses one `group(:saga_class, :current_state).count`; the fleet table and the totals (all/stalled/suspended/compensating) render
- [ ] Overview shell is a turbo-frame that lazy-loads the `classes` frame (the GROUP BY isolated from the cheap card counts)
- [ ] `stalled` lists instances (across all classes) with ≥1 stalled event, showing the parked event name(s); `suspended` lists instances with ≥1 failed event, showing the error class/message
- [ ] All three link rows to the correct saga show page by State PK

**Steps:**

- [ ] **Step 1: routes** — add:
```ruby
  get "overview", to: "overview#index", as: :overview
  scope "overview", as: :overview do
    get "classes", to: "overview#classes"
  end
  resources :stalled, only: :index
  resources :suspended, only: :index
```

- [ ] **Step 2: OverviewQuery**
```ruby
module SagaForge
  module Dashboard
    class OverviewQuery
      def rows
        SagaForge::State.group(:saga_class, :current_state).count
          .each_with_object(Hash.new { |h, k| h[k] = {} }) { |((klass, state), n), acc| acc[klass][state] = n }
      end

      def totals
        stalled = SagaForge::State.where(id: SagaForge::Event.stalled.select(:saga_forge_state_id))
        suspended = SagaForge::State.where(id: SagaForge::Event.failed.select(:saga_forge_state_id))
        {
          all: SagaForge::State.count,
          stalled: stalled.count,
          suspended: suspended.count,
          compensating: SagaForge::State.compensating.count
        }
      end
    end
  end
end
```
(Note: totals use plain COUNT here — the overview page is explicitly the one place chrono accepts a real aggregate, isolated in its own frame. Keep it simple; if scale demands, cap later.)

- [ ] **Step 3: controllers**
```ruby
class OverviewController < BaseController
  def index
    @totals = OverviewQuery.new.totals
  end

  def classes
    @rows = OverviewQuery.new.rows
    render layout: false
  end
end

class StalledController < BaseController
  def index
    @states = SagaForge::State.where(id: SagaForge::Event.stalled.select(:saga_forge_state_id))
      .order(updated_at: :desc).limit(500)
  end
end

class SuspendedController < BaseController
  def index
    @states = SagaForge::State.where(id: SagaForge::Event.failed.select(:saga_forge_state_id))
      .order(updated_at: :desc).limit(500)
  end
end
```
(CAP=500 like chrono's stranded/wait pages; note in a comment.)

- [ ] **Step 4: views** — overview `index` renders stat cards from `@totals` and a `<turbo-frame id="sf-overview-classes" src="<classes path>" loading="lazy">`; `classes` renders the fleet table from `@rows` (rows = saga_class, columns = states) with `layout: false`. `stalled/index` and `suspended/index` render tables: correlation id (link to `saga_path`), saga_class, state badge, and — for stalled — the parked event names (`state.events.stalled.pluck(:event_name)`); for suspended — the failed event's `error["class"]`/`message` (`state.events.failed.first&.error`).

- [ ] **Step 5: tests**
```ruby
# test/overview_query_test.rb
require "test_helper"
class OverviewQueryTest < SagaForge::Dashboard::TestCase
  test "rows group by class and state; totals derive" do
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "a", current_state: "demo_waiting")
    SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "b", current_state: "compensating")
    q = SagaForge::Dashboard::OverviewQuery.new
    assert_equal 1, q.rows["DemoSaga"]["demo_waiting"]
    assert_equal 1, q.totals[:compensating]
    assert_equal 2, q.totals[:all]
  end
end
```
```ruby
# test/stalled_test.rb / test/suspended_test.rb / test/overview_test.rb — each GETs the page and asserts 200 + a seeded instance appears. (Pattern as in sagas_index_test.)
```

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): overview, stalled, and suspended pages

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/queries/saga_forge/dashboard/overview_query.rb", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/overview_controller.rb", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/stalled_controller.rb", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/suspended_controller.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/overview_query_test.rb TEST=test/stalled_test.rb TEST=test/suspended_test.rb", "acceptanceCriteria": ["group-by fleet + totals", "lazy turbo-frame", "stalled/suspended lists with detail"], "requiresUserVerification": false}
```

---

### Task 7: SagaGraph presenter, saga_graph.js, definitions#show graph page

**Goal:** The per-class state-machine graph with a per-instance overlay, rendered with cytoscape.

**Files:**
- Create: `app/presenters/saga_forge/dashboard/saga_graph.rb`
- Create: `app/assets/saga_forge/dashboard/saga_graph.js` (adapted from chrono's `definition_graph.js`)
- Create: `app/controllers/saga_forge/dashboard/definitions_controller.rb`
- Modify: `config/routes.rb` (nested `get :definition` on sagas + a class-level graph route)
- Create: `app/views/saga_forge/dashboard/definitions/show.html.erb`
- Test: `test/saga_graph_test.rb`, `test/definitions_controller_test.rb`

**Acceptance Criteria:**
- [ ] `SagaGraph.new(definition_graph, state=nil).to_h` returns cytoscape `{nodes, edges}`: nodes carry `kind-<start|state|terminal>` + `status-<...>` classes; edges carry `kind-<chain|jump|stay>`
- [ ] With a `state`, overlay marks the current state (`status-active`) and colors states whose events are processed/stalled/failed
- [ ] `definitions#show` embeds `@graph.to_json` in `#sf-graph[data-graph]`, loads cytoscape/dagre/cytoscape-dagre/saga_graph.js, disables polling, renders a legend (chain solid / jump dashed / stay loop, and a best-effort note)
- [ ] Unknown saga class → friendly empty state, not a 500

**Steps:**

- [ ] **Step 1: SagaGraph** (mirrors chrono's `CytoscapeGraph`, consuming our `Graph` DTO):
```ruby
module SagaForge
  module Dashboard
    # Turns a Definition#to_graph (structured nodes+typed edges) into Cytoscape
    # elements, optionally overlaying one instance's status. Rendering-only.
    class SagaGraph
      def initialize(graph, state = nil)
        @graph = graph          # SagaForge::Dashboard::Graph
        @state = state
      end

      def to_h
        {nodes: node_elements, edges: edge_elements}
      end

      private

      def status_map
        return {} unless @state
        @overlay ||= begin
          by_state = {}
          # current state
          by_state[@state.current_state] = :active
          # color states by their events' worst status (failed > stalled > processed)
          @state.events.each do |e|
            st = SagaForge::State # noop guard
            node = @graph.edges.find { |edge| edge.label.to_s.split(" / ").include?(e.event_name) }&.from
            next unless node
            rank = {"failed" => 3, "stalled" => 2, "processed" => 1}[e.status] || 0
            cur = {failed: 3, stalled: 2, processed: 1}[by_state[node]] || 0
            by_state[node] = e.status.to_sym if rank > cur && by_state[node] != :active
          end
          by_state
        end
      end

      def node_elements
        @graph.nodes.map do |n|
          status = status_map[n.id] || :none
          {data: {id: n.id, label: n.label}, classes: "kind-#{n.kind} status-#{status}"}
        end
      end

      def edge_elements
        @graph.edges.each_with_index.map do |e, i|
          {data: {id: "e#{i}", source: e.from, target: e.to, label: e.label.to_s}, classes: "kind-#{e.kind}"}
        end
      end
    end
  end
end
```
(Wrinkle: the event→node attribution via label-splitting is approximate. Prefer, if cheap, resolving the node from the saga's `Definition#state_for_event(event_name)` instead of scanning edge labels — pass the `definition` in and use it. Refactor the constructor to `initialize(graph, definition, state=nil)` and map `definition.state_for_event(e.event_name)` → node id. Do this; it's exact.)

- [ ] **Step 2: saga_graph.js** — copy chrono's `definition_graph.js`, keep the cytoscape+dagre bootstrapping, adjust: parse `#sf-graph[data-graph]`, map `kind-chain`→solid / `kind-jump`→dashed / `kind-stay`→loop styling, `status-active/failed/stalled/processed/none`→colors (indigo current, red failed, amber stalled, green processed, grey none), tap-to-inspect node/edge with neighborhood dimming, client-side `esc` for labels.

- [ ] **Step 3: controller + routes**
```ruby
class DefinitionsController < BaseController
  def show
    @sf_disable_polling = true
    @saga_class = SagaForge::Router.saga_classes.find { |k| k.name == params[:class] }
    return render :missing unless @saga_class
    definition = @saga_class.definition
    @state = params[:correlation_id].present? ? @saga_class.find_by_correlation(params[:correlation_id]) : nil
    @graph = SagaGraph.new(definition.to_graph, definition, @state).to_h
  end
end
```
Routes:
```ruby
  get "definitions/:class", to: "definitions#show", as: :saga_definition, constraints: {class: /[\w:]+/}
```
(And the show page's "view graph" link builds `saga_definition_path(class: @state.saga_class, correlation_id: @state.correlation_id)`.)

- [ ] **Step 4: view** — `definitions/show.html.erb`: a legend, `<div id="sf-graph" data-graph="<%= @graph.to_json %>"></div>`, and the four `<script src=".../assets/<file>?v=<digest>">` tags (cytoscape, dagre, cytoscape-dagre, saga_graph). Add `definitions/missing.html.erb`.

- [ ] **Step 5: tests**
```ruby
# test/saga_graph_test.rb
require "test_helper"
class SagaGraphTest < SagaForge::Dashboard::TestCase
  test "elements carry kind and status classes" do
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d).to_h
    assert h[:nodes].any? { |n| n[:classes].include?("kind-terminal") }
    assert h[:edges].any? { |e| e[:classes].include?("kind-chain") }
  end

  test "overlay marks current state active" do
    s = OrderSaga.find_by_correlation(1) ||
      SagaForge::State.create!(saga_class: "OrderSaga", correlation_id: "1", current_state: "awaiting_settlement")
    d = OrderSaga.definition
    h = SagaForge::Dashboard::SagaGraph.new(d.to_graph, d, s).to_h
    active = h[:nodes].find { |n| n[:data][:id] == "awaiting_settlement" }
    assert_includes active[:classes], "status-active"
  end
end
```
```ruby
# test/definitions_controller_test.rb
require "test_helper"
class DefinitionsControllerTest < SagaForge::Dashboard::TestCase
  test "renders graph data attribute" do
    get "/saga_forge/definitions/OrderSaga"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "data-graph"
  end
  test "unknown class is a friendly empty state" do
    get "/saga_forge/definitions/NopeSaga"
    assert_equal 200, last_response.status
  end
end
```
(These reference `OrderSaga` — add it as a fixture under `test/internal/app/sagas/` in this task, a small multi-state saga with a `transition_to` and a `stay`, so the graph has all three edge kinds. Reuse the core gem's OrderSaga shape.)

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): state-machine graph with per-instance overlay

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/presenters/saga_forge/dashboard/saga_graph.rb", "saga_forge-dashboard/app/assets/saga_forge/dashboard/saga_graph.js", "saga_forge-dashboard/app/controllers/saga_forge/dashboard/definitions_controller.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/saga_graph_test.rb TEST=test/definitions_controller_test.rb", "acceptanceCriteria": ["cytoscape elements + kind/status classes", "overlay active state", "graph page renders", "unknown class friendly"], "requiresUserVerification": false}
```

---

### Task 8: Actions controller + BulkRecoveryJob, wire the buttons

**Goal:** The four operator actions and their bulk variants, POST/CSRF/confirm-guarded.

**Files:**
- Create: `app/controllers/saga_forge/dashboard/actions_controller.rb`
- Create: `app/jobs/saga_forge/dashboard/bulk_recovery_job.rb`
- Modify: `config/routes.rb` (member actions on sagas + bulk on stalled/suspended)
- Modify: show `_actions.html.erb`, stalled/suspended views (bulk buttons)
- Test: `test/actions_test.rb`, `test/bulk_recovery_job_test.rb`

**Acceptance Criteria:**
- [ ] POST `retry_stalled`/`resume`/`compensate`/`cancel` on a State call the matching model method and redirect with a flash; a `false`/no-op result flashes "nothing to do" rather than a success
- [ ] `compensate`/`cancel` require confirm (`data-confirm` in the view) and accept a `reason`
- [ ] Bulk `retry_stalled`/`resume` (from stalled/suspended, scoped to a saga class) enqueue `BulkRecoveryJob`, which iterates the derived scope with `find_each` calling the per-instance method
- [ ] All mutations are POST-only + CSRF-protected

**Steps:**

- [ ] **Step 1: routes**
```ruby
  resources :sagas, only: %i[index show] do
    member do
      post :retry_stalled, to: "actions#retry_stalled"
      post :resume, to: "actions#resume"
      post :compensate, to: "actions#compensate"
      post :cancel, to: "actions#cancel"
    end
  end
  post "bulk/:saga_class/:mode", to: "actions#bulk", as: :bulk_action, constraints: {saga_class: /[\w:]+/, mode: /retry_stalled|resume/}
```
(Merge with the existing `resources :sagas` block from Task 4 — don't duplicate it.)

- [ ] **Step 2: actions controller**
```ruby
module SagaForge
  module Dashboard
    class ActionsController < BaseController
      def retry_stalled = run { @state.retry_stalled! }
      def resume = run { @state.resume! }
      def compensate = run { @state.compensate! }
      def cancel = run { @state.cancel!(reason: params[:reason].presence || "operator") }

      def bulk
        klass = SagaForge::Router.saga_classes.find { |k| k.name == params[:saga_class] }
        return redirect_back(fallback_location: root_path, alert: "Unknown saga class.") unless klass
        BulkRecoveryJob.perform_later(klass.name, params[:mode])
        redirect_back(fallback_location: root_path, notice: "Bulk #{params[:mode]} enqueued for #{klass.name}.")
      end

      private

      def run
        @state = SagaForge::State.find(params[:id])
        did = yield
        redirect_to saga_path(@state), notice: (did ? "Done." : "Nothing to do.")
      end
    end
  end
end
```

- [ ] **Step 3: bulk job**
```ruby
module SagaForge
  module Dashboard
    class BulkRecoveryJob < ActiveJob::Base
      def perform(saga_class, mode)
        scope = SagaForge::State.for_saga(saga_class)
        scope = (mode == "resume") ?
          scope.where(id: SagaForge::Event.failed.select(:saga_forge_state_id)) :
          scope.where(id: SagaForge::Event.stalled.select(:saga_forge_state_id))
        scope.find_each { |state| (mode == "resume") ? state.resume! : state.retry_stalled! }
      end
    end
  end
end
```

- [ ] **Step 4: wire buttons** — in `_actions.html.erb`, `button_to` each action (`method: :post`), gating: Retry stalled shown when `@stalled`; Resume when `@suspended`; Compensate/Cancel always, with `data: {confirm: "..."}`. In stalled/suspended index views, a bulk `button_to bulk_action_path(saga_class: klass, mode: "retry_stalled")` per class group (or a single top button when the list is class-filtered).

- [ ] **Step 5: tests**
```ruby
# test/actions_test.rb
require "test_helper"
class ActionsTest < SagaForge::Dashboard::TestCase
  def csrf_off = SagaForge::Dashboard # forgery disabled in test env (Task 0)
  test "resume flips failed event and redirects" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c1", current_state: "demo_waiting")
    SagaForge::Event.create!(event_id: "e", saga_class: "DemoSaga", correlation_id: "c1", event_name: "demo_done", status: :failed, state: s)
    post "/saga_forge/sagas/#{s.id}/resume"
    assert_equal 302, last_response.status
    assert SagaForge::Event.where(event_id: "e").first.pending?
  end

  test "no-op flashes nothing to do" do
    s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "c2", current_state: "demo_waiting")
    post "/saga_forge/sagas/#{s.id}/retry_stalled"
    follow_redirect!
    assert_includes last_response.body, "Nothing to do"
  end

  test "bulk enqueues job" do
    assert_enqueued_with(job: SagaForge::Dashboard::BulkRecoveryJob) do
      post "/saga_forge/bulk/DemoSaga/resume"
    end
  end
end
```
```ruby
# test/bulk_recovery_job_test.rb
require "test_helper"
class BulkRecoveryJobTest < SagaForge::Dashboard::TestCase
  test "resumes every failed instance of the class" do
    2.times do |i|
      s = SagaForge::State.create!(saga_class: "DemoSaga", correlation_id: "b#{i}", current_state: "demo_waiting")
      SagaForge::Event.create!(event_id: "e#{i}", saga_class: "DemoSaga", correlation_id: "b#{i}", event_name: "demo_done", status: :failed, state: s)
    end
    perform_enqueued_jobs { SagaForge::Dashboard::BulkRecoveryJob.perform_later("DemoSaga", "resume") }
    assert_equal 2, SagaForge::Event.pending.count
  end
end
```
(Note: CSRF is disabled in the test env via `default_protect_from_forgery = false` in Task 0's `environments/test.rb`, so `post` works without a token. Confirm this; the live app keeps CSRF on via `protect_from_forgery`.)

- [ ] **Step 6: run and commit**
```bash
cd saga_forge-dashboard && bundle exec rake
git add saga_forge-dashboard
git commit -m "feat(dashboard): operator actions and bulk recovery

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/app/controllers/saga_forge/dashboard/actions_controller.rb", "saga_forge-dashboard/app/jobs/saga_forge/dashboard/bulk_recovery_job.rb"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake test TEST=test/actions_test.rb TEST=test/bulk_recovery_job_test.rb", "acceptanceCriteria": ["four actions + flash", "no-op message", "bulk job iterates scope", "POST-only"], "requiresUserVerification": false}
```

---

### Task 9: Preview server, README, release tooling, full-suite green

**Goal:** A `bin/dev` seeded preview server, the dashboard README, release rake task extension, and a final green run.

**Files:**
- Create: `saga_forge-dashboard/config.ru`, `bin/dev`
- Create: `saga_forge-dashboard/README.md`, `MIT-LICENSE`
- Modify: monorepo-root release tooling to add `release:dashboard:*` (or document it if the core release tooling isn't built yet — see wrinkle)
- Test: full `bundle exec rake` + manual `bin/dev` smoke

**Acceptance Criteria:**
- [ ] `bin/dev` builds Tailwind then boots the combustion app with `authentication = :none`, `polling_interval = 0`, seeds a rich fixture fleet (running, stalled, suspended, compensating, stuck-compensating, completed, cancelled across ≥2 saga classes), and serves `/saga_forge`
- [ ] `README.md` covers: install (`gem` + `mount`), the three auth modes with the fail-closed default, the config table, the page tour, and a screenshot placeholder section
- [ ] `bundle exec rake` fully green; `standardrb` clean
- [ ] The dashboard gem packages (`gem build saga_forge-dashboard.gemspec` succeeds) and excludes test/ via the `Dir[...]` manifest

**Steps:**

- [ ] **Step 1: config.ru** — model on chrono's `chrono_forge-dashboard/config.ru`: boot Combustion (`:active_record, :active_job, :action_controller`), configure `authentication = :none` + `polling_interval = 0`, then seed inline: create several `State`+`Event` fixtures across two saga classes covering every health state (a normal in-flight saga, one with a stalled event, one with a failed event + traceback, one `compensating` with a `compensated` list, one stuck with `comp_error`, one `completed`, one `cancelled`). `run Combustion::Application`.

- [ ] **Step 2: bin/dev**
```bash
#!/usr/bin/env bash
set -e
bundle exec rake tailwind:build
bundle exec rackup -p "${PORT:-9977}"
```
`chmod +x bin/dev`. (Serves `http://localhost:9977/saga_forge`.)

- [ ] **Step 3: README** — write to the angarium standard (no em dashes), covering install/mount, auth (fail-closed, three modes), config table (`polling_interval`, `page_size`, and the note that display thresholds read from `SagaForge.config`), the page tour (sagas index/show, overview, stalled, suspended, graph), the operator actions, and a "Screenshots" placeholder. `MIT-LICENSE` copied from the core gem.

- [ ] **Step 4: release tooling** — if the monorepo-root release rake tasks exist, add `release:dashboard:*` with tag prefix `saga_forge-dashboard-v` and a Tailwind-rebuild `assets:` hook (mirror chrono's `lib/tasks/release.rake`). If they do NOT exist yet (core release tooling was deferred), instead add a short `## Releasing` note to the dashboard README pointing at the future root tasks, and skip — do not build the core release tooling here. Report which path you took.

- [ ] **Step 5: full run + package check + commit**
```bash
cd saga_forge-dashboard && bundle exec rake && gem build saga_forge-dashboard.gemspec && rm -f saga_forge-dashboard-*.gem
git add saga_forge-dashboard
git commit -m "feat(dashboard): preview server, README, packaging

Claude-Session: https://claude.ai/code/session_01BYH5LNyvj7LpuyJCQkDYTy"
git push origin main
```

```json:metadata
{"files": ["saga_forge-dashboard/config.ru", "saga_forge-dashboard/bin/dev", "saga_forge-dashboard/README.md"], "verifyCommand": "cd saga_forge-dashboard && bundle exec rake", "acceptanceCriteria": ["bin/dev seeds + serves", "README complete no em dashes", "rake green", "gem builds"], "requiresUserVerification": false}
```

---

## Task dependency graph

```
T0 (scaffold) ──┬─ T2 (auth+assets) ── T3 (layout/helper/css) ──┬─ T4 (index) ── T5 (show) ──┐
                │                                                ├─ T6 (overview/stalled/suspended)
                │                                                └─ T7 (graph)
                └─ T1 (core: to_graph) ───────────────────────────── T7 (graph)
T5, T6, T7 ── T8 (actions) ── T9 (preview/readme/release)
```

## Self-review notes

- Spec coverage: §1 repo/packaging → T0; §2 chassis → T0/T2/T3; §3 core additions → T1; §4 queries/presenters → T4/T5/T6/T7; §5 pages → T4/T5/T6/T7; §6 graph → T1/T7; §7 actions → T8; §8 testing → every task + T9; §9 deferred → untouched.
- No user-verification requirement (automated tests + developer-driven preview), so no verification task.
- The one genuine risk is the `SagaGraph` event→node attribution: the plan resolves it exactly via `definition.state_for_event` (Task 7 wrinkle), not label-splitting.

## Known follow-ups (surfaced during review, deliberately deferred)

- **Overview stat-card counts aren't in the lazy frame** (Task 6 review). `overview#index` computes the four totals synchronously, and the `stalled`/`suspended` counts touch `saga_forge_events`, so on a very large fleet the non-lazy shell can be slow even though the GROUP BY is isolated in its frame. Plan-sanctioned "simplify now"; if scale demands, move the stat cards into their own lazy turbo-frame.
- **No fleet-wide `compensating` triage page** (Task 6 review). The overview's Compensating card falls back to `sagas_path(filter: "compensating")` on the first saga class. Add a dedicated cross-class page if operators need it.
- **Triage controller duplication** (Task 6 review). `StalledController`/`SuspendedController` share the CAP/order/batch-load shape; extract a shared helper if a third triage page lands (rule of three).
- **`Definition#to_graph` re-scans handler source per request** (Task 7 review). `to_graph` (and its `jump_targets`/`stay_targets`) re-run the `RubyVM::InstructionSequence` block-extent scan on every graph-page load, and the `data-graph` JSON is inlined into an HTML attribute. Fine for realistic saga sizes (a handful to a few dozen states); if sagas ever rival chrono workflow sizes, cache the compiled graph and/or fetch it via a frame instead of inlining.
- **saga_graph.js shares cytoscape boilerplate with chrono's definition_graph.js** (Task 7 review). Two independent gems today; a shared JS helper is a cross-repo call if the interaction logic ever needs to stay in lockstep.
```

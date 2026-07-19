# SagaForge Dashboard — Design

**Date:** 2026-07-19
**Status:** Approved for planning
**Phase:** 2 (the core gem, phase 1, is complete and shipped)

A mountable Rails engine gem, `saga_forge-dashboard`, that gives operators a
read-mostly management dashboard over SagaForge: browse saga instances, read
the event ledger as a timeline, see which sagas are stalled or suspended,
view each saga's state-machine graph with a per-instance overlay, and run the
four recovery actions. Modeled closely on `chrono_forge-dashboard`'s chassis;
adapted to saga concepts.

---

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Graph rendering | **Cytoscape, assembled dashboard-side.** Reuse chrono's vendored cytoscape + dagre JS. A dashboard-side `SagaGraph` presenter builds a structured `{nodes, edges}` from `Definition#to_graph` and overlays per-instance status. Richest interactivity; not mermaid. |
| Core-gem additions | **Minimal.** Add `Definition#to_graph` (structured DTO) and a `State.compensating` scope to the core gem; everything else (merged timeline, count-by-state) stays dashboard-side. |
| v1 page set | **Core set.** sagas index/show, overview, stalled, suspended, definition graph. No branch/repetition pages (sagas have neither); no analytics in v1. |
| Operator actions | **Four actions + bulk.** Per-instance `retry_stalled!`/`resume!`/`compensate!`/`cancel!` (CSRF, confirm on destructive), plus bulk `retry_stalled`/`resume` on the list views via a background job. |
| Repo location | Sub-gem `saga_forge-dashboard/` inside the saga_forge monorepo, mirroring `chrono_forge-dashboard/`. |

## 1. Repo & packaging

- Mountable `Rails::Engine`, namespace `SagaForge::Dashboard`, at
  `saga_forge-dashboard/` in the saga_forge repo.
- Own gemspec / `version.rb` / CHANGELOG / Gemfile / test suite. File manifest
  ships `lib/`, `app/`, `config/`, `app/assets/**` as plain files (assets are
  served by a controller, not Sprockets/Propshaft).
- Runtime deps: `saga_forge` (released-gem dep in the gemspec; **path dep in
  dev** via `gem "saga_forge", path: ".."`), `railties >= 7.1`,
  `actionpack >= 7.1`. No ActiveRecord dep of its own — it rides the core
  models.
- Core gemspec already rejects `saga_forge-dashboard/` from its manifest
  (present since phase 1), so the two gems package independently.
- Mounted by the host: `mount SagaForge::Dashboard::Engine => "/saga_forge"`.
  Engine routes `root to: "sagas#index"`.
- Release tooling extends the monorepo-root rake tasks planned for the core:
  `release:dashboard:*` (prepare/publish), tag prefix `saga_forge-dashboard-v`
  (core uses `v`), git-cliff scoped by path, the dashboard release recompiles
  Tailwind so it never ships stale CSS, bare `rake release` neutralized in
  both Rakefiles.
- `lib/saga_forge/dashboard.rb` top-level module: `require "saga_forge"`
  first, then version/configuration/engine; `ASSET_ROOT`; `config` /
  `configure` / `reset_configuration!`; and `asset_digest(file)` (memoized
  SHA256 of the asset file, `[0,12]`, `rescue`-falls back to `VERSION`).
- `lib/saga_forge/dashboard/engine.rb`: minimal — `isolate_namespace
  SagaForge::Dashboard`, no asset-pipeline hooks.

## 2. Chassis (ported near-verbatim from chrono_forge-dashboard)

**Auth (fail-closed)** — `BaseController < ActionController::Base`, `layout`,
`protect_from_forgery with: :exception`, `before_action :authenticate!`.
Resolution order: `authenticate` hook (`instance_exec`ed in the controller) →
`http_basic` (constant-time `ActiveSupport::SecurityUtils.secure_compare`,
single `&` so both compares always run) → `:none` → raise
`AuthenticationNotConfigured` (a heredoc naming the three fixes). Nothing
configured means locked, by design.

**Self-served assets** — `AssetsController < BaseController` with
`skip_before_action :authenticate!` + `skip_forgery_protection`. A `TYPES` MIME
allowlist; verify the path is a real file; set
`Cache-Control: public, max-age=31536000, immutable`; `send_file`. The route
also constrains `:file` with a regex allowlist (defense in depth). Views build
asset URLs manually with the per-boot digest:
`"#{request.script_name}/assets/dashboard.css?v=#{SagaForge::Dashboard.asset_digest("dashboard.css")}"`.

**Tailwind v4** — source `app/assets/saga_forge/dashboard/tailwind.css` →
minified `dashboard.css` via `rake tailwind:build` (`tailwindcss-ruby`); `rake
build` enhanced to depend on it. Indigo accent (matching the site) rather than
chrono's orange.

**Vendored JS** — `turbo.min.js` (auto-refresh via idiomorph),
`cytoscape.min.js`, `dagre.min.js`, `cytoscape-dagre.js` (graph), `saga_graph.js`
(adapted from chrono's `definition_graph.js`), `dashboard.js` (poll region,
confirm-dialog delegation, time toggle). All checked in, served by the assets
controller.

**Turbo-morph auto-refresh** — `<main data-poll-region>` refreshed on an
interval (idiomorph preserves filter text/focus/scroll); per-page opt-out
(`@sf_disable_polling`) used by the graph page. Interval selector +
relative/absolute time toggle in the header, cookie-backed.

**Configuration** — `SagaForge::Dashboard.configure { |c| ... }`:
`http_basic`, `authentication`, `authenticate(&block)`, `polling_interval`
(default 15), `polling_interval_options`, `page_size` (default 50). Display
thresholds (`stall_budget`, `retention`) are read live from `SagaForge.config`,
never duplicated.

## 3. Core-gem additions (minimal, each its own tested commit)

These land in the **core** `saga_forge` gem, because they are generally useful
to any consumer, not just the dashboard:

- **`SagaForge::Definition#to_graph`** — a structured, serializable graph
  value object:
  - **Nodes**: a synthetic `start` node (`Definition::START`), one per
    `during` state, one per terminal state; each carries `{id, label, kind}`
    where kind ∈ `start | state | terminal` (terminals include the implicit
    `:compensated` / `:cancelled`).
  - **Edges**: typed —
    - `:chain` edges from the linear successor chain
      (`[START] + during_states + [first terminal]`), labeled with
      `events_for_state(from).join(" / ")`.
    - `:jump` edges from `jump_targets` (the existing best-effort literal
      `transition_to :sym` source-scan).
    - `:stay` self-loops from a **new** best-effort `stay` source-scan
      (`stay_targets`), reusing the same `RubyVM::InstructionSequence`
      block-extent machinery `jump_targets` uses.
  - Each edge carries `{from, to, kind, label}`; handler metadata
    (`compensate`, `timeout`, `on_timeout`) is available for edge annotation.
  - Honest about the dynamic verbs: `:jump` and `:stay` are best-effort
    (computed targets are silently omitted), matching `to_mermaid`'s existing
    caveat. `:chain` is complete and reliable.
  - `to_mermaid` stays as-is; `to_graph` is the structured sibling.
- **`SagaForge::State.compensating`** scope — `in_state(COMPENSATING)`. (The
  `stalled` / `suspended` scopes already exist from phase 1; the
  "stuck compensating" case — `comp_error` present — is a jsonb-path read the
  dashboard does itself, since it is unindexed and dashboard-specific.)

No merged-timeline or count-by-state helpers in core; those live in the
dashboard's presenters/queries.

## 4. Data layer: queries + presenters

Two read layers, matching chrono's separation, tuned to avoid `COUNT(*)` and
`OFFSET` at scale.

**Queries** (`app/queries/saga_forge/dashboard/`):
- `SagasQuery` — keyset (cursor) pagination over `State.for_saga(klass)`,
  ordered by PK, paging with `id < cursor` / `id > cursor`, fetching `per+1`
  to detect more, never COUNTing. Prefix-safe `correlation_id LIKE
  sanitize_sql_like(q) + "%"` to ride the `[saga_class, correlation_id]`
  index. Virtual filters `stalled` / `suspended` / `compensating` compose the
  derived scopes (`State.stalled` / `.suspended` / `.compensating`). `MAX_PER`
  cap.
- `StatsQuery` — capped index-only counts per state for the filter chips:
  `State.from(relation.select(:id).limit(CAP), :capped).count`, rendered as
  "5000+" when saturated. `CAP` constant.
- `OverviewQuery` — one `State.group(:saga_class, :current_state).count`
  GROUP BY feeds the whole fleet table; keeps the enum-normalization guard
  (raw int vs label) chrono uses.

**Presenters** (`app/presenters/saga_forge/dashboard/`):
- `TimelinePresenter` — builds one chronological stream for a saga instance by
  merging `state.history` (Event rows: `event_name`, `status`, `attempts`,
  `stall_count`, `error`, `created_at`) with the compensation progress read
  from `context["__saga_forge"]` (`compensated` LIFO list, `comp_attempts`,
  `comp_error`). The engine does not pre-merge these (see §7 of the
  introspection notes), so the dashboard owns the merge. Each entry carries a
  status badge, timestamp, and expandable detail (payload / error traceback /
  retry budgets).
- `ContextPresenter` — a JSON tree of the user's `context`, per-key type and
  byte size, with the reserved `__saga_forge` sub-hash surfaced in its own
  labeled section (failure_reason, target, compensated, comp_attempts,
  comp_error) rather than mixed in with user keys.
- `SagaGraph` — consumes `Definition#to_graph` for the class, overlays a
  specific instance: marks the current state, and colors states by whether
  their events are processed / parked (stalled) / failed, by joining
  `state.events`. Emits cytoscape `{nodes, edges}` structured elements (no
  text-grammar escaping bugs). Synthesizes any endpoint nodes the overlay
  references but the node list lacks.

A `DashboardHelper` module carries the shared view helpers: state badges/pills,
relative/absolute time toggle, CSP-safe bar-width classes, duration and byte
formatting, poll-interval cookie logic.

## 5. Pages

Views under `app/views/saga_forge/dashboard/`; layout at
`app/views/layouts/saga_forge/dashboard/application.html.erb` (loads
`dashboard.css` + `turbo.min.js` in `<head>`, header nav Sagas / Overview /
Stalled / Suspended, interval selector, time toggle, flash-toast region,
`<main data-poll-region>`, `dashboard.js` at end of body).

- **sagas#index** — a saga-class picker (from `SagaForge::Router.saga_classes`,
  enumerated live per reload), filter chips (all / stalled / suspended /
  compensating / by current_state), keyset Newer/Older nav, a
  `correlation_id` prefix search. Table rows: correlation id, current state
  badge, version, updated-at, health flag (stalled/suspended/stuck). Partials:
  `_stats`, `_filters`, `_saga_row`.
- **sagas#show** — summary banner (current state; callouts for stalled /
  suspended / stuck-compensating with the reason); the event-ledger
  **timeline** (`TimelinePresenter`); a **compensation panel** when relevant
  (LIFO `compensated` progress, per-comp attempts, `comp_error` traceback);
  the **context tree** (`ContextPresenter`); a link to the class's
  **definition graph** with this instance overlaid. Action buttons
  (Retry stalled / Resume / Compensate / Cancel) gated by state. Composed from
  partials: `_summary`, `_timeline`, `_compensation`, `_context_tree`,
  `_actions`.
- **overview** — fleet by `saga_class` × `current_state`
  (`OverviewQuery` GROUP BY), isolated in its own turbo-frame so it never
  blocks the cheap per-page counts; stat cards for total / stalled /
  suspended / compensating across all classes.
- **stalled** — instances with ≥1 parked event (`State.stalled`), the
  "missing webhook / early arrival" view; each row links to the saga and shows
  the parked event name(s) and stall_count.
- **suspended** — instances with ≥1 failed event (`State.suspended`), the
  "there's a bug" view; each row surfaces the failed event's error class and
  message, with the traceback one click away.
- **definitions#show** — the per-class state-machine graph (§6), with an
  optional `?correlation_id=` to overlay a specific instance. Polling disabled.

No branch-children, repetitions, wait-states, or analytics pages: sagas have
no branch/repeat primitives, "waiting" is folded into stalled, and analytics
is deferred past v1.

## 6. The graph (end to end)

1. `DefinitionsController#show`: `@sf_disable_polling = true`; look up the saga
   class from `SagaForge::Router.saga_classes` (rescue unknown →
   friendly empty state); `klass.definition.to_graph`.
2. If a `correlation_id` is given, load the `State` and hand it to `SagaGraph`
   for the overlay; otherwise render the bare class graph.
3. `SagaGraph#to_h` → cytoscape `{nodes, edges}`; embedded as JSON in
   `#sf-graph[data-graph]` (ERB-escaped attribute); a legend for edge kinds
   (chain solid, jump dashed, stay self-loop) and node status colors.
4. Load `cytoscape.min.js`, `dagre.min.js`, `cytoscape-dagre.js`,
   `saga_graph.js`. The JS parses the attribute, registers dagre, maps
   kind→shape / status→color / edge-kind→line-style, lays out top-to-bottom,
   and offers tap-to-inspect on nodes and edges (event labels, compensations,
   timeouts) with neighborhood dimming. Client-side `esc` on any label that
   reaches `innerHTML`.

The graph is honest about the dynamic verbs: chain edges are complete; jump
and stay edges are best-effort (a computed `transition_to` won't appear). A
short legend note says so, matching `to_mermaid`'s existing caveat.

## 7. Actions (operator mutations)

`ActionsController < BaseController`:
- `retry_stalled` → `state.retry_stalled!`
- `resume` → `state.resume!`
- `compensate` → `state.compensate!` (confirm dialog)
- `cancel` → `state.cancel!(reason: params[:reason])` (confirm dialog)
- `bulk_retry_stalled` / `bulk_resume` — count the target set up front for the
  flash, then enqueue `SagaForge::Dashboard::BulkRecoveryJob`.

Guards: POST-only routes; `button_to method: :post` in views; CSRF via
`protect_from_forgery` + the layout's csrf meta tag; `data-confirm` on the
destructive actions, handled by a delegated submit listener in `dashboard.js`.
The operator methods return booleans (`retry_stalled!`/`resume!` →
`count > 0`; `compensate!`/`cancel!` → transitioned?); the controller turns a
`false`/no-op into a friendly "nothing to do" flash rather than a silent
success.

`BulkRecoveryJob < ActiveJob::Base` — `perform(saga_class, mode)` iterates the
matching scope (`State.for_saga(klass).stalled` or `.suspended`) with
`find_each`, calling the per-instance method. Idempotent and safe to re-run
(the operator methods are status-scoped from phase 1).

## 8. Testing

- Minitest + minitest-reporters; engine tested via Combustion +
  `action_controller/railtie` + `active_job/railtie` + `rails/test_help` +
  `rack-test`. `test/internal` dummy app mounts the engine at `/saga_forge`
  and defines sample saga classes (a happy multi-state saga, one that fails,
  one that compensates) as the fixtures the pages and graph render.
- `config.ru` + `bin/dev` seed-and-preview server: boots the same Combustion
  app with `authentication = :none` and `polling_interval = 0` (stable for
  screenshots), seeds a rich fixture fleet inline (running, stalled,
  suspended, compensating, stuck-compensating, completed, cancelled), and
  serves `http://localhost:<port>/saga_forge` for browser dev and screenshots.
- Test files per layer: `auth`, `assets`, `configuration`, `sagas_query`,
  `stats_query`, `overview_query`, `timeline_presenter`, `context_presenter`,
  `saga_graph`, `definitions_controller`, `sagas_index`, `sagas_show`,
  `overview`, `stalled`, `suspended`, `actions`, `bulk_recovery_job`, plus a
  `smoke` test. Core-gem additions (`Definition#to_graph`, `stay_targets`,
  `State.compensating`) are tested in the **core** gem's suite, not the
  dashboard's.

## 9. Deferred (explicitly out of this design)

- Analytics page (event throughput / processed-vs-failed over time, the
  heaviest adapter-coupled piece).
- A public Pages site / screenshot tour (follows once the dashboard exists,
  reusing the core gem's `site/` and pages workflow with a screenshots step).
- Any write surface beyond the four operator actions + their bulk variants.

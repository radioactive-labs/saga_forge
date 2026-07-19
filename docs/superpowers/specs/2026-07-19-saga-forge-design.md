# SagaForge — Design

**Date:** 2026-07-19
**Status:** Approved for planning
**Semantic contract:** the v5 API specification (Appendix A, verbatim). This
document adds the build design: how the spec maps onto a concrete repo,
which patterns are ported from chrono_forge and angarium, and the decisions
made during brainstorming.

SagaForge is a saga engine for Rails on ActiveJob / Solid Queue:
MassTransit's state machine, ChronoForge's spirit. One imperative saga file
read top to bottom, one saga table, one event ledger, commit-at-end
atomicity, event-level stalling with parking, LIFO compensation.

---

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Queue coupling | **Adapter-agnostic.** Correctness on any ActiveJob adapter via pessimistic row lock + optimistic version check at commit (chrono_forge-style locking). When Solid Queue is the adapter, `ExecutionJob` additionally declares `limits_concurrency` on `"SagaLock:#{saga_class}:#{correlation_id}"` as a throughput optimization. No solid_queue gem dependency. |
| Dashboard scope | **Full dashboard, phased after core.** Core gem built to spec first; `saga_forge-dashboard` engine gem follows in the same repo, modeled on chrono_forge-dashboard. |
| Multi-DB / base class | **Angarium pattern.** `SagaForge::ApplicationRecord < ActiveRecord::Base` (abstract) calling `connects_to` at class load from `config.database` / `config.connects_to`; migrations shipped in `db/saga_forge_migrate/`; install generator with `--database` flag; `primary_key_type` cascade. Zero config → host's primary connection. (Not chrono_forge's `ApplicationRecord()` host-inheritance pattern.) |
| Repo strategy | **Greenfield, port selectively.** New repo; infrastructure ported nearly verbatim from chrono_forge (retry policies, lock strategy, generator machinery, test harness, release tooling, dashboard chassis); the saga engine itself written fresh to the spec — its event-driven semantics share little code with chrono's replay executor. |
| ChronoForge interop | **No gem dependency.** Composition is user-level: a saga block kicks off a chrono workflow; the workflow's completion publishes an event the saga awaits. |

## 1. Repo & packaging

Monorepo at `plutonium/saga_forge`, mirroring chrono_forge's two-gem layout:

- **Core gem** at the repo root: plain gem (no Rails engine, no railtie).
  Zeitwerk via `Zeitwerk::Loader.for_gem` with `loader.ignore` on
  `lib/generators` (Rails' generator machinery loads those). Runtime deps:
  `activerecord (>= 7.1)`, `activejob (>= 7.1)`, `zeitwerk`. Ruby >= 3.2.
  Gemspec manifest via `git ls-files`, explicitly rejecting
  `saga_forge-dashboard/`, `bin/`, `test/`, `docs/`, `site/`.
- **`saga_forge-dashboard/`** sub-gem (phase 2): a `Rails::Engine`
  (`isolate_namespace SagaForge::Dashboard`), own gemspec/version/CHANGELOG/
  Gemfile (path-dep on the core in dev, released-gem dep in the gemspec),
  own test suite.
- **Release tooling** ported from chrono_forge: per-gem git-cliff release
  rake tasks (`release:core:*` / `release:dashboard:*`), tag prefixes `v` and
  `saga_forge-dashboard-v`, path-scoped changelogs, neutralized bare
  `rake release`, dashboard release recompiles Tailwind before packaging,
  CI cuts GitHub Releases from tags but never pushes to RubyGems.
- **Tooling:** `standard` (linter), `appraisal`, Minitest +
  `minitest-reporters`, Combustion, `chaotic_job`, `strong_migrations`,
  `bundle-audit`. Two-lane CI: appraisal test matrix + a PostgreSQL 16
  migration-safety job.
- Docs paper trail continues in `docs/superpowers/{specs,plans}`.

## 2. Data layer & multi-DB (angarium pattern)

- `SagaForge::ApplicationRecord` — abstract, `< ActiveRecord::Base`.
  At class load: `connects_to(**config.connects_to)` if set, else
  `connects_to database: {writing: db, reading: db}` if `config.database`
  set, else nothing (primary connection). Read once at load — safe because
  initializers run before models are first touched.
- **Models:**
  - `SagaForge::State` → `saga_forge_states`: UUID/bigint PK (via
    `SagaForge.primary_key_type` cascade), `saga_class` + `correlation_id`
    (unique compound index), `current_state`, `version` (optimistic
    concurrency counter), JSONB `context`, index `[saga_class, current_state]`.
  - `SagaForge::Event` → `saga_forge_events`: `event_id` (producer
    idempotency key, unique index; payload-digest fallback), `saga_class`,
    `correlation_id`, nullable backfilled FK to the state row, `event_name`,
    JSONB `payload`, `status` (pending/processed/stalled/failed),
    `stall_count`, `attempts`, JSONB `retry_budgets`, JSONB `error`.
    Indexes: `[saga_class, correlation_id, status]`, `[status, created_at]`,
    `[saga_forge_state_id, created_at]`.
  - JSONB on PG, JSON elsewhere (`t.respond_to?(:jsonb)` guard).
- **Migrations:** canonical copies in `db/saga_forge_migrate/` (never
  `db/migrate` — keeps Rails from auto-appending them to the primary
  connection). `saga_forge:install` generator writes a documented
  initializer (rewriting the `config.database =` line when `--database=NAME`
  is passed) and invokes `saga_forge:migrations`, which uses
  `ActiveRecord::Migration.copy` into `db/migrate` (default or
  `--database=primary`) or `db/NAME_migrate`, and prints the `database.yml`
  stanza (`migrations_paths:`) plus `bin/rails db:migrate:NAME` next steps.
  Re-runs are idempotent. No-flag runs fall back to
  `config.migrations_database` (database, else connects_to writing role).
- **Atomicity across databases:** all engine writes go through
  `SagaForge::ApplicationRecord.transaction`, so the single-commit contract
  holds on whichever database hosts the two tables. External
  `SagaForge.publish` INSERTs join the *caller's* open transaction only when
  the caller shares the engine's connection; on a split database the
  not-found → bounded retry → discard absorption in `ExecutionJob` covers
  the enqueue-before-commit race regardless.

## 3. Core runtime components (`lib/saga_forge/`)

- **`base.rb`** — `SagaForge::Base`: the DSL macros (`correlate_by`,
  `start_with`, `during`, `finish_with`, `compensation`, `retry_policy`)
  which only record declarations, plus the class-level operator/introspection
  surface (`find_by_correlation`, `in_state`, `stalled`, `suspended`,
  `to_mermaid`) delegating to `SagaForge::State` scoped by `saga_class`.
- **`definition.rb`** — immutable boot-compiled metadata per saga class:
  states in file order, chain successors (start → first `during` state →
  next distinct state → first `finish_with`), `state_event_map`,
  event → handler registry (block, `compensate:`, `timeout:`/`on_timeout:`,
  retry policy), compensation catalog, terminal states. All §8 boot
  validations (`AmbiguousEventError`, `UnknownCompensationError`,
  `MissingCorrelationError`, `NoTerminalStateError`, reachability warnings).
  `to_mermaid` renders from it: chain edges solid, `transition_to` jumps
  dashed via a best-effort literal scan of handler blocks (jumps are
  otherwise opaque; unresolvable targets are simply not drawn).
- **`router.rb`** — global boot-time event → saga-class registry; resolves
  recipients and correlation values (`correlate_by` symbol or block with
  `(payload, event_name)`), raising `MissingCorrelationError` naming the
  class with zero rows inserted. Owns the shared row builder used by both
  publish paths.
- **`publisher.rb`** — external `SagaForge.publish`: resolve → INSERT rows
  joining any open transaction (never `requires_new`) → enqueue one
  `ExecutionJob` per row after it. `event_id:` dedup via unique index;
  payload-digest fallback. Raises `UnstagedPublishError` when called inside
  saga execution — a per-execution flag in
  `ActiveSupport::IsolatedExecutionState` wrapped around user block
  invocation only (forward, compensation, and timeout blocks). The engine
  never calls the public publish itself.
- **`execution_job.rb`** — the §4 pipeline: load event row (not found →
  brief bounded retry, then silent discard) → processed-skip → halt check
  (any `failed` event for this instance → leave pending, exit) → stall check
  (registered state vs `current_state`; spin with `retry_job(wait:
  config.stall_wait)` up to `config.stall_budget`, then park as `stalled`;
  spins never touch retry budgets) → run handler block in memory via the
  execution facade → single commit: lock state row FOR UPDATE, verify
  `version`, write state/context, mark event `processed`, insert staged
  recipient rows → after the transaction: enqueue jobs for inserted rows,
  arm/refresh timeout, re-deliver parked events matching the new state in
  ledger order. Declares `limits_concurrency` on
  `"SagaLock:#{saga_class}:#{correlation_id}"` only when the Solid Queue
  adapter is active.
- **`execution/` (facade + runner)** — the `saga` object yielded to blocks:
  staged `context` hash, `publish` (eager router resolution at the call
  site; staged rows held in memory), `transition_to` (validated against
  declared states), `stay`, `fail!(reason:)`, read-only `correlation_id` /
  `current_state`. Retry-policy application on errors (per-`during` →
  class-level → site default: forward 3 attempts/cap 30s, compensation 10
  attempts/cap 600s); exhaustion or unmatched error → event row `failed`
  with traceback, nothing escapes to ActiveJob's dead-letter path.
- **`compensation_runner.rb`** — on `fail!` / `compensate!` / `cancel!`:
  read this instance's `processed` events in ledger order, map through the
  boot-time event → `compensate:` registry, dedupe to distinct handlers, run
  LIFO under the same commit-at-end + tolerant retry contract, terminal
  `:compensated` (or `:cancelled` for `cancel!`). `compensate!` warns when
  failed events exist (resume-then-compensate rule).
- **`retry_policy.rb` / `composite_retry_policy.rb`** — ported from
  chrono_forge nearly verbatim: value object (max_attempts, base, cap,
  equal jitter, `retry_on`), composites with independent per-declared-error
  budgets, tracked in the event row's `attempts` / `retry_budgets`.
- **`timeout_job.rb`** — armed at each commit that enters or re-handles an
  event in a state with `timeout:`, carrying the saga version; on fire,
  discarded if the version moved (stale timer), else synthesizes the
  `on_timeout:` action (`:fail!` or a state name) through the normal commit
  path. Clock resets on each handled event.
- **`sweeper_job.rb`** — re-enqueues aged `pending` rows (the delivery
  guarantee; enqueues are hints). Host-scheduled; docs ship a Solid Queue
  `recurring.yml` snippet. A companion retention job prunes `processed`
  events past `config.retention`, only for sagas in a terminal state.
- **`configuration.rb`** — `stall_wait`, `stall_budget`, `sweep_interval`,
  `retention`, `job_queue`, `database`, `connects_to`, `primary_key_type`,
  plus `migrations_database` helper for the generators.

## 4. Error handling & operator surface

Per the spec: stalls and failures live on **event rows**, never the saga
row — `current_state` never lies. Whole-instance halt while a `failed`
event exists. Runtime `UnknownStateError` raises inside the uncommitted
transaction; events for terminal-state instances are marked `processed`
with a discard note. Operator methods on `SagaForge::State`:
`retry_stalled!`, `resume!`, `compensate!`, `cancel!(reason:)`, plus
`history` and `events.stalled` / `events.failed`. `stalled` / `suspended`
are derived scopes (EXISTS subqueries on the ledger), not stored status.

## 5. Testing

- Minitest + Combustion internal app (`test/internal/` with sample sagas
  under `app/sagas`, migration copies, sqlite default / PG lane via
  `DB_ADAPTER`).
- `chaotic_job` fault injection around the commit boundary — the key
  torture targets: no ghost cascades from failed blocks (staged publishes
  never surface), exactly-once staged-row insertion across re-runs,
  parking + in-order re-delivery, halt discipline, version-race retries,
  LIFO compensation derivation with `stay` loops.
- Generator tests copying angarium's matrix: default → `db/migrate`,
  `--database=NAME` → `db/NAME_migrate`, `--database=primary` →
  `db/migrate`, no-flag + configured database → configured path;
  initializer rewrite assertions.
- `strong_migrations` active at boot on the PG CI lane.
- Appraisal across supported Rails versions.

## 6. Dashboard (phase 2, same repo)

`saga_forge-dashboard` engine gem modeled on chrono_forge-dashboard:

- **Chassis:** fail-closed auth (`http_basic` constant-time / custom
  `authenticate` block / explicit `:none`; unconfigured raises), self-served
  digest-busted assets via an allowlisted `AssetsController` (no host asset
  pipeline dependency), Tailwind v4 compiled ahead-of-time by rake, vendored
  Turbo + Cytoscape/dagre, queries/presenters/controllers layering, keyset
  pagination, no `COUNT(*)` on hot paths.
- **Pages:** sagas index (filter by class/state/derived scopes) and show
  (current state, context, chronological ledger timeline with per-event
  status/attempts/error, parked and failed events surfaced); stalled and
  suspended views; overview (stat cards, turbo-frame sections); analytics;
  state-machine graph rendered from `Definition` metadata (solid chain,
  dashed jumps) with per-instance overlay of the current state and
  processed events.
- **Actions:** the four operator methods + bulk variants, executed via
  dashboard jobs.
- **Not ported:** chrono_forge's Prism `DefinitionAnalyzer` — SagaForge's
  chain is declared in macros, so the graph comes free from `Definition`.

---

## Appendix A — SagaForge API Specification (v5, verbatim semantic contract)

MassTransit's state machine, ChronoForge's spirit. Sagas for Rails on
ActiveJob / Solid Queue: one imperative file read top to bottom, one saga
table, one event ledger, commit-at-end atomicity, event-level stalling with
parking, LIFO compensation.

**Core principles:**

1. **States exist only at genuine async boundaries** — places the saga parks
   because the next fact comes from outside (webhook, human, another saga,
   time). Synchronous work chains inline in blocks.
2. **Events are durable facts, not job payloads.** Every event is persisted to
   the ledger *before* any job runs. Jobs carry only an event row ID.
3. **The saga row never lies.** `current_state` is always the true workflow
   position. Stalls and failures are recorded on the *event* that stalled or
   failed — never by mutating the saga's state.
4. **One execution semantic.** A block re-runs whole until it commits; external
   calls are idempotent. No checkpointing, no memoization, no sub-steps —
   retry granularity is tuned by splitting states, and work that needs
   internal step durability belongs in a ChronoForge workflow the saga awaits.

### A.1 The Saga class

```ruby
# app/sagas/order_fulfillment_saga.rb
class OrderFulfillmentSaga < SagaForge::Base
  correlate_by :order_id
  retry_policy max_attempts: 5, base: 2, cap: 60      # class-wide default (optional)

  start_with :order_placed, compensate: :refund_payment do |saga, payload|
    saga.context[:items] = payload[:items]
    charge = PaymentGateway.charge(payload[:total], idempotency_key: saga.correlation_id)
    saga.context[:transaction_id] = charge.id
  end                                             # ⇒ falls through to :awaiting_settlement

  during :awaiting_settlement, on: :payment_settled, compensate: :release_inventory do |saga, _payload|
    Warehouse.reserve(saga.context[:items], key: saga.correlation_id)
    Shipping.dispatch(saga.correlation_id)
    saga.publish :order_fulfilled, order_id: saga.correlation_id   # delivered on commit
  end                                             # ⇒ falls through to :completed

  during :awaiting_settlement, on: :payment_failed do |saga, payload|
    saga.fail! reason: payload[:decline_code]     # branch: ends explicitly (convention)
  end

  finish_with :completed

  compensation :refund_payment do |saga|
    return unless saga.context[:transaction_id]   # self-guard: context records what happened
    PaymentGateway.refund(saga.context[:transaction_id],
                          idempotency_key: "refund:#{saga.correlation_id}")
  end

  compensation :release_inventory do |saga|
    Warehouse.release(saga.context[:items], key: saga.correlation_id)
  end
end
```

The file **is** the state machine. Side effects run directly in blocks — no
consumer classes, no internal command events, no checkpointed sub-steps.
Blocks execute in a worker with no lock or transaction held; atomicity comes
from the single commit (§A.4).

#### Grammar (class macros)

| Macro | Meaning |
|---|---|
| `correlate_by :key` or `correlate_by { \|payload, event\| … }` | How this saga recognizes itself in a payload. Symbol = sugar for `{ \|p\| p[:key] }`. Block form gets the event name as an optional second arg (per-event vocabularies, composite keys). Must be pure — it runs inside every publish. Required, one per class. |
| `start_with :event do …` | Kickoff. Creates the saga row for new correlation IDs. |
| `during :state, on: :event do …` | Handler for one event in one state. The event→state pair is the stall table. |
| `finish_with :state` | Terminal state. Multiple allowed. Required (≥1). |
| `compensation :name do \|saga\| …` | Rollback catalog entry. Takes only the saga; reads everything from `context`; self-guards for conditional cases. |
| `retry_policy …` | Class-wide default retry policy (§A.5). |

Handler options on `start_with` / `during`: `compensate: :name` (this step's
rollback — registered by the fact the step processed, see §A.4), `timeout:` /
`on_timeout:`, `retry_policy:`.

#### The chain (default flow)

Built at boot from **file order**: `start_with` → first `during` state → next
*distinct* `during` state → … → first `finish_with`. A block that completes
without an explicit exit advances to its state's successor; all handlers of a
state share the successor. Reordering `during` blocks rewires the workflow —
intentional (inserting a state splices it in), but block order is semantic.

#### Verbs (inside blocks)

| Verb | Meaning |
|---|---|
| *(fall through)* | Advance to the successor. The 90% case. |
| `saga.transition_to :state` | Jump: branching, skipping, rejoining the mainline. Undeclared target ⇒ `UnknownStateError`, raised inside the uncommitted transaction. |
| `saga.stay` | Remain in this state; handle the event again later (loops, partial progress). |
| `saga.fail!(reason: nil)` | Halt forward flow, run the compensations of processed steps LIFO (§A.4), transition to `:compensated`. |
| `saga.context` | JSONB-backed hash; staged in memory, persisted at commit. Also the sole input to compensations — write what rollback will need; treat compensation-read keys as append-only (arrays/maps for repeats). |
| `saga.publish :event, **payload` | Emit a fact for other sagas — **staged, delivered only on success**. Recipients resolved eagerly at the call site; their inbound rows insert atomically with this block's commit (§A.2). Discarded by `fail!`. Usable in compensation blocks. |
| `saga.correlation_id` / `saga.current_state` | Read-only identity and position at block entry. |

#### Branching

Two mechanisms, no condition DSL — conditions are plain Ruby:

- **Event-driven** (the world decides): multiple `during` blocks on one state,
  one per incoming event. Convention: non-happy-path handlers end explicitly.
- **Data-driven** (your code decides): `if` + `transition_to`; fall through on
  the other path. Rejoining is free — a detour's last state transitions back
  into the mainline.

**Unordered arrival is handled by ordered states + parking (§A.3), not by
composite events.** Two facts arriving in unpredictable order are modeled as
two sequential states; the early arrival parks and is re-delivered when the
saga advances. Arrival order is free; processing order is deterministic — side
effects and the compensation ledger always execute in declared order, which a
"fire when all constituents observed" composite cannot promise. `all_of` is
**rejected**, not deferred: it would reintroduce N-events-per-state (breaking
free stalling), hide join progress in context flags, and stop `current_state`
naming what the saga waits on.

**Fan-out parallelism** (N concurrent legs) = child sagas: parent publishes
child kickoff events, children publish completion events, parent consumes them
as sequential states — parking makes completion order irrelevant. Likewise,
**a single step needing internal step-level durability** (many expensive
sub-calls, resumable mid-sequence) is a ChronoForge workflow: the block kicks
it off, the saga awaits its completion event. Composition over absorption.

#### Waiting: timeouts

```ruby
during :awaiting_settlement, on: :payment_settled,
       timeout: 30.minutes, on_timeout: :fail! do |saga, payload|
```

`on_timeout:` takes `:fail!` or a state name (timeout-as-branch). Implemented
as a scheduled job staged at transition time; a stale timer firing late is
discarded by the same state check that powers stalling. **The clock resets on
each handled event** (a `stay` loop making progress is not timing out); total
residence in a state is a dashboard concern, not a timeout one.

### A.2 The event ledger: publish is persist-first

Two entry points, one rule — an event exists iff its publisher's world is real:

```ruby
# OUTSIDE saga execution — webhook controllers, jobs, models:
SagaForge.publish :payment_settled, event_id: "settle:#{order.id}",
                   order_id: 42, transaction_id: "tx_9"

# INSIDE a saga block — staged, delivered only if this block commits:
saga.publish :order_confirmed, total: saga.context[:total]
```

`SagaForge.publish` persists immediately: the external fact already happened
(the webhook arrived), so the ledger records it now. `saga.publish` **stages**:
the fact isn't ratified until the block commits, so recipients' rows are
written *inside the final commit* — publish-on-success. Calling
`SagaForge.publish` from within saga execution raises `UnstagedPublishError`:
an event that fires even when its block fails is exactly the ghost-cascade
footgun the staged verb exists to close (a plain enqueued job is the escape
hatch if immediate fire is truly wanted — enqueueing is itself a
fire-even-on-failure side effect, so a job that publishes is the honest way
to announce a world-fact that should survive the block's rollback).

*Guard mechanics:* a per-execution flag (`ActiveSupport::IsolatedExecutionState`,
thread- and fiber-safe) wrapped around the **user block invocation only** —
compensation and timeout blocks included. The engine never calls the public
`SagaForge.publish` itself (staged rows are inserted directly), so
there is no exemption path to design, misuse, or even reason about. The
guard is a footgun-catcher, not a sandbox — spawned threads or later-running
jobs escape it, deliberately.

Events are **broadcast facts**: one publish fans out to every saga class that
registers the event. Need narrower delivery? Name the event more
specifically — don't target classes.

Publishing means:

1. **Router resolves recipients** (boot-time metadata): every saga class
   registering the event via `start_with` / `during … on:`. For each class,
   the correlation value comes from its `correlate_by` — the symbol key, or
   the block invoked with `(payload, event_name)`:

   ```ruby
   # Producer publishes once, with each recipient's key present:
   SagaForge.publish :payment_settled, event_id: "settle:#{order.id}",
                      order_id: 42, shipment_ref: "SHP-9"

   # OrderFulfillmentSaga:  correlate_by :order_id             → instance 42
   # ShipmentSaga:          correlate_by { |p, event|            → instance SHP-9
   #                          event == :payment_settled ? p[:shipment_ref]
   #                                                    : p[:shipment_id] }
   ```

   Registration is the claim "this event is for me" — so a `correlate_by`
   returning nil (or raising) is a producer/consumer contract bug: the
   **whole publish fails atomically** (`MissingCorrelationError` naming the
   class, zero rows inserted). For `saga.publish`, resolution happens
   **eagerly at the call site** — the error surfaces inside the block, under
   its retry policy, before anything is staged. No partial delivery, no
   silent skips. One event resolves **one instance per class**; N instances
   of one class need N publishes — each fact is about one subject.
   Query-based multicast is a deliberate non-feature (iterate a scope,
   publish per instance).
2. **INSERT one inbound ledger row per recipient** — `status: pending`,
   carrying `saga_class` + `correlation_id` (FK to the saga row is nullable
   and backfilled: `start_with` events precede the row's existence).
3. **Enqueue one `ExecutionJob` per row** (row ID as the only argument), via
   ActiveJob's after-commit enqueueing.

**Insert in the transaction; enqueue after it.** `SagaForge.publish` splits
into two halves: the row INSERTs **join** any open transaction (never
`requires_new`), and the job enqueues happen **outside** it. For the engine's
own commit (§A.4) this is trivially sequential code — the enqueue loop is the
next statement after the `transaction` block, using the row IDs already in
hand from eager resolution. No ActiveJob deferral feature, no adapter
detection, no Rails-version dependency.

The `pending` row is the delivery obligation; the enqueue is a hint; the
**sweeper is the delivery guarantee** (crash between commit and enqueue →
swept; duplicate enqueue → processed-skip). The one race: an external
`SagaForge.publish` inside a *caller's* transaction enqueues before their
commit. `ExecutionJob` absorbs it — row not found → brief bounded retry (the
row appears when their commit lands) → then **silent discard** (they rolled
back; a rollback dropping its hints is exactly right). Worst-case delivery
latency is floored at `sweep_interval`, on any adapter, any topology.

**The outbox guarantee without the outbox.** `saga.publish` resolves
recipients **once, at the call site** (where you want the
`MissingCorrelationError` stack trace), and holds fully-built row attributes.
At commit time the engine **inserts those precomputed rows directly** —
plain model inserts inside its own transaction, never touching
`SagaForge.publish`, which is external-only. The two paths share the internal
router + row builder, nothing more. Staged publishes *are* the recipients'
inbound rows, inserted in the publisher's commit: recipients' events exist
**iff the publisher committed**, ghost cascades from failed blocks are
impossible, and recipients can never race a commit whose rows don't exist
yet. Insertion is **exactly-once** for saga-to-saga events (a re-run of a
failed block re-stages rows that were never inserted; a re-delivery after
commit sees `processed` and skips), so staged payloads need no determinism
discipline — timestamps are fine. What you see resolved at the call site is
exactly what commits — there is no second resolution to agree with.

**Publish idempotency (external boundary only).** For `SagaForge.publish`,
pass `event_id:` as the idempotency key; the unique index no-ops duplicates
(webhook redelivery). Without an explicit `event_id:`, dedup falls back to
event name + payload digest — which requires the payload to be deterministic
across the producer's retries.

#### Inbound event lifecycle

```
pending ──processed          handled successfully; audit trail
   │
   ├───── stalled            arrived early / orphaned; PARKED, saga untouched
   │         └─ re-delivered automatically when the saga's state advances
   └───── failed             processing poison-pilled; traceback stored; saga untouched
             └─ blocks further processing for this saga until resolved
```

### A.3 Ordering safety: stalling and parking

1. Per-instance serialization: Solid Queue `limits_concurrency` on
   `"SagaLock:#{saga_class}:#{correlation_id}"` (when Solid Queue is the
   adapter; see Decisions — correctness never depends on it).
2. `ExecutionJob` loads its event row, compares the event's registered state
   (`state_event_map[event]`) with the saga's `current_state`.
3. **Mismatch** → the event is early (predecessor mid-retry) →
   `retry_job(wait: config.stall_wait)`. Cheap queue-spin for the common
   seconds-long case.
4. **Stall budget exhausted** → the event row goes `status: stalled` and stops
   consuming queue cycles. **The saga row is not touched.**
5. **Self-healing:** whenever a commit advances `current_state`, the engine
   re-delivers parked events registered for the new state, **in ledger order**
   (insertion order; producer timestamps are advisory metadata only).

Stall re-enqueues are **not retries** — they never touch any retry budget
(chrono's `wait_until` lesson: being early isn't an error).

#### Failure isolation

A block that raises an unmatched error, or exhausts its retry policy, marks
its **event row** `failed` with the full traceback. Nothing was committed, so
the saga row is consistent and untouched. While a saga has a `failed` event,
the engine refuses to process further events for it (they accumulate as
`pending`) — running past a poison pill compounds damage. The halt applies to
the whole instance; a per-event `skippable:` escape hatch is deliberately
deferred until real usage demands it. The halt is derived from the ledger at
job entry, not stored on the saga.

"Stalled" and "suspended" sagas are **derived scopes**, not states:

```ruby
OrderFulfillmentSaga.stalled     # sagas with ≥1 stalled event (usually: missing webhook)
OrderFulfillmentSaga.suspended   # sagas with ≥1 failed event  (usually: a bug)
```

### A.4 Execution & atomicity contract

```
[ ExecutionJob(event_row_id) ]
  ├─ load event row; not found → brief retry (pre-commit race), then discard (§A.2)
  ├─ skip if already processed (idempotent re-delivery)
  ├─ halt check: saga has a failed event? → leave pending, exit
  ├─ stall check: registered state vs current_state → spin / park (§A.3)
  ├─ run block IN MEMORY   ← real side effects; saga.publish resolves + STAGES; no DB lock held
  └─ BEGIN TRANSACTION
       lock saga row FOR UPDATE; verify version     ← optimistic concurrency
       write state / context                        ← incl. resolved transition
       mark event row processed
       insert staged recipient rows (precomputed at call site)  ← publish-on-success
     COMMIT
  └─ enqueue ExecutionJobs for the inserted rows   ← next statement after the txn; crash → sweeper
  └─ re-deliver parked events matching the new state
```

A crash or retryable error before COMMIT leaves no trace; the block re-runs
**whole, from the top**. This is the entire execution model:

> **Blocks must be idempotent.** Every external call carries an idempotency
> key — convention: `saga.correlation_id`, plus a step qualifier when one saga
> makes several calls of the same kind (`"refund:#{saga.correlation_id}"`).
> On a re-run, completed calls no-op at the boundary that actually matters
> (Stripe, the warehouse) and return their original results.

Each event's processing is the unit of atomic re-run. If whole-block re-runs
get expensive — several slow external calls where a late failure re-executes
the earlier ones — **split the state**: that's what states are for (the second
reason after async waits). If a single step needs finer-grained internal
durability than that, delegate it to a ChronoForge workflow and await its
completion event.

#### Compensation is derived, not stored

There is no compensation ledger. "Which compensations are owed" is a pure
function of **which events processed** — and the event ledger records exactly
that. On `fail!` (or `compensate!`), the engine:

1. Reads this instance's `processed` inbound events, in ledger order.
2. Maps each through the boot-time `event → compensate:` registry
   (unique — event→handler already is).
3. Dedupes to **distinct handlers** (a `stay` loop that processed five
   `item_packed` events owes one compensation run, not five — correct because
   compensations read full accumulated context).
4. Runs them **LIFO**, under the same commit-at-end, retry-per-policy contract
   as forward blocks. Completion transitions to `:compensated`.

The structural guarantee this buys: **a step is compensable iff it
committed** — the same row flip (`processed`) that records the step implies
its compensation. Nothing is staged mid-block, so nothing can be forgotten
mid-block. Compensations take no arguments because **context is the
snapshot**: everything rollback needs was written by the forward block and
committed atomically with it. The one convention that carries: later steps
must not clobber context keys that earlier steps' compensations read
(append via arrays/maps for repeated values).

#### The sharp edge, now structural: failed steps aren't compensable yet

If a block's external call succeeds but the block fails, the side effect
happened while the event stayed `failed` — so it implies no compensation,
*and* its context contributions never committed, so even a manually invoked
compensation's guard sees nothing to undo. Both facts point the same
direction. Operational rule — **resume, then compensate**: fix the code,
`resume!` (the idempotent re-run commits the facts: event → `processed`,
context populated), then compensate if still desired. `compensate!` on a saga
with failed events emits a warning to this effect.

### A.5 Retry policies (ChronoForge-shaped)

`RetryPolicy` is a value object: `max_attempts` (nil = unbounded), `base`,
`cap`, `jitter` (equal jitter), `retry_on` — nil = any StandardError, `[]` =
retry nothing, a list matches those classes and subclasses. Backoff:
`min(cap, base × 2^(attempts−1))`, jitter applied at re-enqueue, never
persisted.

**Composites:** an array — first policy matching the raised error applies,
each with an independent attempt budget keyed by its *declared* errors (stable
under reordering); unmatched errors fail fast; catch-all (`retry_on: nil`)
last. Attempt counts and per-error budgets are tracked on the event row.

**Resolution:** per-`during` override → class-level `retry_policy` DSL →
site default.

```ruby
retry_policy max_attempts: 5, base: 2, cap: 60          # kwargs form, or positional composite:
# retry_policy RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5),
#              RetryPolicy.new(retry_on: nil, max_attempts: 2)

during :awaiting_settlement, on: :payment_settled, retry_policy: [
  RetryPolicy.new(retry_on: [Net::ReadTimeout],   max_attempts: 5),
  RetryPolicy.new(retry_on: [Carrier::RateLimit], max_attempts: 10, base: 5),
  RetryPolicy.new(retry_on: [Payment::Declined],  max_attempts: 1)
] do |saga, payload|
  ...
end
```

Site defaults: forward blocks = step default (3 attempts, cap 30s, any error —
fail fast); compensation blocks = tolerant default (10 attempts, cap 600s —
giving up mid-rollback is worse). Exhaustion or an unmatched error ⇒ the event
row goes `failed` (§A.3); nothing escapes to ActiveJob's dead-letter queue.

### A.6 Configuration

```ruby
SagaForge.configure do |config|
  config.stall_wait            = 3.seconds
  config.stall_budget          = 40             # queue-spins before parking
  config.sweep_interval        = 30.seconds     # pending-row recovery
  config.retention             = 90.days        # processed events, prunable only after a saga reaches
                                                # a terminal state (active sagas derive compensation
                                                # from their processed-event history)
  config.job_queue             = :sagas
end
```

### A.7 Introspection & recovery

```ruby
OrderFulfillmentSaga.find_by_correlation(42)
OrderFulfillmentSaga.in_state(:awaiting_settlement)
OrderFulfillmentSaga.stalled                # derived: has parked events
OrderFulfillmentSaga.suspended              # derived: has failed events

record.history                              # ledger rows, chronological
record.events.stalled / record.events.failed
record.retry_stalled!                       # re-deliver parked events now
record.resume!                              # re-fire failed event(s) after a code fix
record.compensate!                          # run the ledger LIFO (warns if events are failed — see §A.4)
record.cancel!(reason:)                     # compensate, then transition to :cancelled

OrderFulfillmentSaga.to_mermaid             # chain edges solid; transition_to jumps dashed
```

The post-rollback terminal is **`:compensated`** (rollback completed) —
distinct from a `failed` *event* (processing broke) and from `:cancelled`
(operator choice). `fail!` with an empty ledger still terminates in
`:compensated` with the reason recorded; the dashboard renders it as
"failed, nothing to undo."

### A.8 Validation

**At boot** (class load):

| Check | Error |
|---|---|
| Event registered under two states in one saga | `AmbiguousEventError` |
| `compensate:` naming an undeclared `compensation` | `UnknownCompensationError` |
| Missing `correlate_by` | `MissingCorrelationError` |
| No `finish_with` | `NoTerminalStateError` |
| Chain state unreachable / dead-ended (best-effort; jumps are opaque) | warning |

**At runtime**, inside the event's processing (loud, harmless — nothing
committed):

- `transition_to` target not declared → `UnknownStateError`
- Event for a terminal-state instance → row marked `processed` with a discard
  note (logged, not an error)

### A.9 Schema

**`saga_forge_states`** — the saga's ground truth, and *only* the truth:

- UUID PK; `saga_class` + `correlation_id` (unique compound index)
- `current_state` — always the real workflow position; no status column
- `version` — internal monotonic counter (optimistic concurrency)
- JSONB `context` — workflow scratchpad *and* compensation snapshot
- Index `[saga_class, current_state]` for dashboards

**`saga_forge_events`** — the ledger (inbound only — there are no outbound
rows); append-only rows, mutable status:

- UUID PK
- `event_id` — producer-supplied idempotency key (unique index; payload
  digest fallback when absent)
- `saga_class`, `correlation_id`; nullable FK to the saga row (backfilled)
- `event_name`, JSONB `payload`
- `status`: pending / processed / stalled / failed; `stall_count`
- `attempts`, JSONB `retry_budgets` (per-error composite budgets)
- JSONB `error` (traceback for failed rows)
- Indexes: `[saga_class, correlation_id, status]` (halt + parking),
  `[status, created_at]` (sweeper), `[saga_forge_state_id, created_at]` (history)

Two tables. That's the whole footprint.

### A.10 Design ledger

| Decision | Rationale |
|---|---|
| Side effects inline; no consumer jobs, no internal command events | Commit-at-end removed the held-lock problem; whole workflow in one file |
| States only at async boundaries | Sync work chains inline; kills state proliferation at the root |
| Default-advance by file order; `transition_to` only for jumps; explicit `stay` | One flow mechanism; chronological reading; static chain for validation |
| Events persisted before jobs run; jobs carry only a row ID | At-least-once from the moment of publish; dedup by index; audit trail for free |
| **`saga.publish` staged, delivered on success — the outbox guarantee without the outbox** | Events aren't inert side effects: a ghost event from a failed block *cascades* into downstream workflows that never park on the publisher's state. Persist-first makes the fix free — staged publishes ARE the recipients' inbound rows, inserted atomically with the commit. Exactly-once insertion (no payload-determinism discipline for saga-to-saga); `SagaForge.publish` inside block execution raises |
| **Delivery = precomputed rows inserted in the transaction, enqueues follow it in plain code; `SagaForge.publish` is external-only** | `saga.publish` resolves once at the call site and holds row attributes; the engine inserts them directly and enqueues as the next statement after its `transaction` block — no ActiveJob deferral, no adapter detection, no second resolution to keep consistent, no guard exemption to design. Rows are the obligation, enqueues are hints, the sweeper is the guarantee; the one external-caller race is absorbed by not-found → retry → discard |
| **Events broadcast to all registered sagas; class-scoped publish dropped** | Events are facts, not addressed messages; narrowness comes from naming, not targeting |
| **`correlate_by` takes a block (payload, optional event); nil fails the whole publish** | The saga's entire self-recognition logic in one place — per-event vocabularies and composite keys via plain Ruby instead of per-handler options scattered through the file; registration = "this is for me," so an unextractable correlation is a loud contract bug, never a silent skip or partial delivery |
| Stall/failure recorded on the event, never the saga | `current_state` never lies; suspended/stalled are derived scopes |
| Parking + re-delivery on advance, in ledger order | Out-of-order arrival self-heals; deterministic processing order |
| Composite events (`all_of`) rejected | Ordered states + parking give arrival-order tolerance *with* deterministic processing; composites break one-event-per-state |
| Fan-out = child sagas, event-driven join | Chrono's `branch`/`merge` pattern, minus the merge poller |
| **Checkpointing / memoization rejected** | A second execution semantic (skipped blocks, return-value discipline, serialization contract, a third table, mini-transactions inside the one-commit model) bought only finer retry granularity — which splitting states already provides. Whole-block re-run + external idempotency keys is one rule that covers everything |
| **Step-level durability delegated to ChronoForge** | A block needing resumable sub-steps kicks off a chrono workflow and awaits its completion event; composition over absorption |
| Event-sourcing `replay!` rejected | The saga row is correct by construction; old-events-through-current-code is unsound when file order is semantics |
| ChronoForge retry policies wholesale | Value object + composites + per-error budgets, proven in production; tracked on the event row |
| Stall spins never consume retry budget | Being early isn't an error |
| Timeout clock resets per handled event | A `stay` loop making progress isn't timing out |
| Whole-instance halt on failed event; `skippable:` deferred | Safety default; add the escape hatch when usage demands it |
| Terminal `:compensated`; `:cancelled` for operator aborts | Failure of an event ≠ fate of the saga |
| **Compensation declared on the handler (`compensate:`); ledger derived, not stored** | "What's owed" is a pure function of which events processed — already recorded in the event ledger; `compensation_ledger` was a hand-maintained cache. A step is compensable iff it committed, by construction |
| **Compensations take no args; context is the snapshot** | Everything rollback needs was written by the forward block and committed atomically with it; self-guarding blocks cover conditional cases. Convention: compensation-read keys are append-only |
| Resume-then-compensate rule | A failed step implies no compensation *and* left no context — both by construction; the idempotent re-run commits the facts before rollback |
| No condition DSL | Ruby `if` beats invented syntax |

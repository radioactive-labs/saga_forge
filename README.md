# SagaForge

[![CI](https://github.com/radioactive-labs/saga_forge/actions/workflows/main.yml/badge.svg)](https://github.com/radioactive-labs/saga_forge/actions/workflows/main.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Sagas for Rails on ActiveJob**: one Ruby file per workflow, a durable event
ledger, out-of-order events that heal themselves, and automatic rollback of
every committed step when something downstream fails.

The moment a workflow spans more than one system ("charge the card, reserve
the stock, dispatch the shipment"), the failure cases start arriving one at a
time: the settlement webhook that lands before your own transaction commits,
the same webhook delivered twice, the payment that fails after inventory was
already reserved, the poison event that should stop the world for one order
but not for the other ten thousand. SagaForge is a saga engine that handles
all of it. You write a single class that reads top to bottom; SagaForge
persists every incoming event before touching it, parks the ones that arrive
early, commits each step atomically, and when a step declares failure, unwinds
the steps that already committed, in reverse order.

Two tables, a handful of jobs, plain Ruby classes, and no separate server to
run. A management dashboard, in the style of ChronoForge's, is planned as a
companion gem. Works with any ActiveJob backend on Rails 7.1+.

### 30-second tour

A saga is one file. States exist only where the next fact comes from outside
(a webhook, a human, another saga); everything else chains inline:

```ruby
# app/sagas/order_fulfillment_saga.rb
class OrderFulfillmentSaga < SagaForge::Base
  correlate_by :order_id
  retry_policy max_attempts: 5, base: 2, cap: 60      # class-wide default (optional)

  # Kick off payment. The gateway acknowledges immediately with a PENDING
  # intent; no money has moved yet. Settlement is decided out of band and
  # arrives later as a webhook: that is the async boundary the next state
  # parks on.
  start_with :order_placed, compensate: :cancel_payment do |saga, payload|
    saga.context[:items] = payload[:items]
    intent = PaymentGateway.create_intent(payload[:total], idempotency_key: saga.correlation_id)
    saga.context[:intent_id] = intent.id
  end                                             # falls through to :awaiting_settlement

  # The webhook controller announces the outcome:
  #   SagaForge.publish :payment_settled, event_id: webhook.id, order_id: order.id
  during :awaiting_settlement, on: :payment_settled, compensate: :release_inventory do |saga, _payload|
    Warehouse.reserve(saga.context[:items], key: saga.correlation_id)
    Shipping.dispatch(saga.correlation_id)
    saga.publish :order_fulfilled, order_id: saga.correlation_id   # delivered on commit
  end                                             # falls through to :completed

  during :awaiting_settlement, on: :payment_failed do |saga, payload|
    saga.fail! reason: payload[:decline_code]     # unwinds committed steps, in reverse
  end

  finish_with :completed

  compensation :cancel_payment do |saga|
    next unless saga.context[:intent_id]          # self-guard: context records what happened
    PaymentGateway.cancel_or_refund(saga.context[:intent_id],   # cancel if pending, refund if settled
                                    idempotency_key: "undo:#{saga.correlation_id}")
  end

  compensation :release_inventory do |saga|
    Warehouse.release(saga.context[:items], key: saga.correlation_id)
  end
end
```

The rest of the world talks to it by publishing facts:

```ruby
# From a webhook controller, a job, a model callback, anywhere outside a saga:
SagaForge.publish :payment_settled, event_id: "settle:#{webhook.id}", order_id: 42
```

SagaForge handles the rest: persisting the event before any job touches it,
parking it if it arrived early, retrying the handler on transient errors,
halting the one instance that hit a poison pill, and keeping a queryable
ledger of everything that happened. See
[Delivery guarantees](#delivery-guarantees) for exactly what is promised.

## Installation

Add to your Gemfile:

```ruby
gem "saga_forge"
```

Then:

```bash
bundle install
bin/rails g saga_forge:install
bin/rails db:migrate
```

`saga_forge:install` writes the initializer and installs SagaForge's migration
in one step. For a separate database, pass `--database=NAME` (see
[Multiple databases](#multiple-databases)). After a gem update, run
`bin/rails g saga_forge:upgrade` to copy any migrations your app is missing;
it skips what you already have, so it is safe to run on every upgrade.

Saga classes live in `app/sagas/`. SagaForge eager-loads that directory on
each boot and code reload, so every saga is registered with the event router
even in development, where Rails would otherwise load classes lazily.

## Defining a saga

Six macros make up the whole grammar:

| Macro | Meaning |
| --- | --- |
| `correlate_by :key` or `correlate_by { \|payload, event\| ... }` | How this saga recognizes itself in a payload. The symbol form reads `payload[:key]`; the block form gets the event name too, for per-event vocabularies or composite keys. Required, one per class. |
| `start_with :event do ...` | The kickoff. Creates the saga instance when a new correlation id shows up. Exactly one per class. |
| `during :state, on: :event do ...` | Handles one event in one state. One event maps to exactly one state per saga; registering it twice is a boot error. |
| `finish_with :state` | Declares a terminal state. At least one required; multiple allowed. |
| `compensation :name do \|saga\| ...` | A rollback step, referenced from handlers via `compensate: :name`. |
| `retry_policy ...` | Class-wide default retry policy (see [Retries](#retries)). |

Handlers take options: `compensate:` (the rollback owed once this step
commits), `timeout:` and `on_timeout:` (see [Timeouts](#timeouts)), and
`retry_policy:` (a per-handler override).

### The chain

The default flow is built from file order: `start_with`, then each distinct
`during` state in the order it first appears, then the first `finish_with`. A
block that completes without an explicit verb advances to its state's
successor. Reordering `during` blocks rewires the workflow; that is
intentional (inserting a state splices it into the chain), but it means block
order is semantics, not style.

Definitions are validated at boot: a missing `correlate_by`, an event
registered under two states, a `compensate:` naming an undeclared
compensation, a `timeout:` without `on_timeout:` (or the reverse), or a
missing `finish_with` all raise when the class loads, not at 3am when the
timer fires.

### Verbs

Inside a handler block, `saga` responds to:

| Verb | Meaning |
| --- | --- |
| (fall through) | Advance to the state's declared successor. The common case. |
| `saga.transition_to :state` | Jump: branch, skip, or rejoin the mainline. An undeclared target raises. |
| `saga.stay` | Remain in this state and handle the event again later (loops, partial progress). |
| `saga.fail!(reason: nil)` | Halt forward flow and run the compensations of every committed step, last first. |
| `saga.context` | A JSON-backed hash, staged in memory and persisted at commit. Also the sole input to compensations: write what rollback will need. |
| `saga.publish :event, **payload` | Emit a fact for other sagas, delivered only if this block commits. |
| `saga.correlation_id` / `saga.current_state` | Read-only identity and position at block entry. |

The last verb called wins; only `fail!` stops the block mid-flight.

### Branching

There is no condition DSL. Data-driven branches are plain Ruby (`if` plus
`transition_to`, fall through on the other path); event-driven branches are
multiple `during` blocks on the same state, one per event the world might
send, as `payment_settled` / `payment_failed` above. A detour rejoins the
mainline by transitioning back into it.

Two facts that arrive in unpredictable order are modeled as two sequential
states. The early arrival parks and is re-delivered automatically when the
saga reaches its state (see [Ordering](#ordering-early-events-park-and-self-heal)),
so arrival order is free while processing order stays deterministic.

## Publishing events

There are two ways an event reaches a saga, and they are not interchangeable.

**`SagaForge.publish(event_name, event_id: nil, **payload)`** is the external
entry point: call it from controllers, webhook handlers, jobs, anywhere
outside saga execution. The event is persisted first (the row inserts join
whatever transaction is open at the call site) and one `ExecutionJob` per
recipient is enqueued right after. `event_id:` is the producer's idempotency
key; a duplicate publish (a webhook redelivery, say) no-ops against a unique
index. Omit it and a deterministic digest of the event name and payload is
used instead, which is fine as long as the payload is identical across the
producer's retries. Calling it from inside a saga block raises
`SagaForge::UnstagedPublishError`, because that is almost always the
ghost-event bug described next.

**`saga.publish(event_name, **payload)`** is the verb inside saga blocks,
compensations included. Recipients are resolved immediately (so a missing
correlation key fails loudly at the call site, under the block's retry
policy), but the rows are only staged in memory. The step's own commit inserts
them, atomically with the state transition that produced them. A block that
raises, or calls `fail!`, discards everything it staged; nothing it published
ever surfaces. Without this, a failed step's events would cascade into
downstream sagas that have no idea the step was rolled back.

Events are broadcast facts, not addressed messages. One publish fans out to
every saga class that registers the event, and each recipient extracts its own
correlation id via its `correlate_by`:

```ruby
SagaForge.publish :payment_settled, event_id: "settle:#{order.id}",
                  order_id: 42, shipment_ref: "SHP-9"

# OrderFulfillmentSaga:  correlate_by :order_id                     -> instance 42
# ShipmentSaga:          correlate_by { |p, _| p[:shipment_ref] }   -> instance SHP-9
```

Registering an event is the claim "this event is for me", so a `correlate_by`
that returns nil for a registered event is treated as a contract bug: the
whole publish fails with `MissingCorrelationError` naming the class, and zero
rows are inserted. There are no silent skips and no partial deliveries. Need
narrower delivery? Name the event more specifically.

## Ordering: early events park and self-heal

Every incoming event is registered (through the saga's definition) for exactly
one state. When an event's job runs, SagaForge compares that registered state
with the saga's current state:

1. Match: the handler runs.
2. Early (the saga has not reached that state yet, or does not exist yet):
   the job re-enqueues itself with a short wait (`config.stall_wait`, default
   3 seconds) and tries again. Being early is not an error; these spins never
   touch any retry budget.
3. Still early after `config.stall_budget` spins (default 3): the event
   parks as `stalled` and stops consuming queue cycles. The saga itself is
   untouched.
4. Whenever a commit advances the saga's state, parked events registered for
   the new state are re-delivered automatically, in the order they were
   recorded.

So a `review_passed` webhook that arrives before `payment_settled` waits its
turn, and the saga processes both in the declared order no matter what order
the network delivered them in.

### The stall budget

The two knobs multiply into how long an early event keeps spinning before it
parks: `stall_budget` spins of `stall_wait` each, so the default 3 by 3
seconds is roughly nine seconds of cheap queue-spinning. It is a floor, not an
exact clock, since each spin is a re-enqueue and adds a little queue latency.
Those spins cost nothing but queue cycles and never consume a retry attempt.

Size the budget to how far out of order you actually expect events to arrive.
The default absorbs a predecessor that lags by up to about nine seconds, which
covers a webhook provider having a slow moment. If a predecessor event
routinely lags further (a settlement that can take ten minutes to confirm, an
upstream saga that runs long), raise `config.stall_budget` so the follower
waits it out instead of parking and waiting for the sweeper. Lower
`config.stall_wait` to spin more tightly when you want early events picked up
faster and don't mind the extra enqueues.

Parking is not a dead end. It just stops the busy-wait: a parked event costs
nothing until it is re-delivered. Re-delivery happens the moment a commit
lands the saga in the event's state (the commit's own after-effects flip every
matching `stalled` row back to `pending` and re-enqueue it, resetting the
budget), and `SagaForge::SweeperJob` re-checks parked events on its own cadence
as a backstop, so an event whose saga advanced during a crash is still
recovered. You can also force it by hand with `record.retry_stalled!`.

Events for a saga already in a terminal state are marked processed with a
discard note (logged, harmless). Truly orphaned events (a correlation id no
saga ever starts) park and show up in the `stalled` scope for an operator to
inspect.

### Poison pills halt one instance, not the system

A handler that exhausts its retries marks its event row `failed` with the full
traceback. While an instance has a failed event, SagaForge refuses to process
further events for that instance; they accumulate as `pending` and nothing is
lost. Other instances are unaffected. `YourSaga.suspended` lists the stuck
instances; fix the code, deploy, and call `resume!` (see
[Operator API](#operator-api)).

## The execution model

Each event is processed as one atomic unit:

1. The handler block runs in memory, with no lock and no open transaction.
   Side effects (API calls, mail, other services) happen here.
2. One transaction then commits everything: the saga row is locked, its
   version is checked (a concurrent commit loses cleanly and retries), the
   new state and context are written, the event flips to `processed`, and any
   staged publishes insert.
3. After the commit: staged events enqueue their jobs, parked events for the
   new state re-deliver, and timeout timers arm.

A crash or a retryable error before the commit leaves no trace; the block
re-runs whole, from the top. That is the entire model, and it puts one
requirement on your code: **blocks must be idempotent at the external
boundary**. Give every external call an idempotency key. The convention is
`saga.correlation_id`, plus a qualifier when one saga makes several calls of
the same kind (`"undo:#{saga.correlation_id}"`). On a re-run, completed calls
no-op at the boundary that actually matters (the payment gateway, the
warehouse) and return their original results.

If whole-block re-runs get expensive (several slow external calls where a
late failure re-executes the earlier ones), split the state: that is what
states are for. A single step that needs internal, resumable sub-steps is a
[ChronoForge](https://github.com/radioactive-labs/chrono_forge) workflow the
saga kicks off and awaits (see
[SagaForge or ChronoForge?](#sagaforge-or-chronoforge)).

## Retries

A retry policy is a value object: `max_attempts` (nil for unbounded), `base`
and `cap` for exponential backoff (`min(cap, base * 2^(attempts-1))`, with
equal jitter), and `retry_on` (nil retries any `StandardError`, `[]` retries
nothing, a list matches those classes and their subclasses).

Resolution order: per-handler `retry_policy:` override, then the class-wide
`retry_policy` macro, then the site default (3 attempts, 30 second cap).
Compensation blocks use a far more tolerant default (10 attempts, 10 minute
cap), because giving up halfway through a rollback is worse than retrying for
a while.

Pass an array for a composite policy: the first entry matching the raised
error applies, each with its own independent attempt budget, so a rate limit
can retry ten times while a decline fails fast:

```ruby
during :awaiting_settlement, on: :payment_settled, retry_policy: [
  SagaForge::RetryPolicy.new(retry_on: [Net::ReadTimeout],   max_attempts: 5),
  SagaForge::RetryPolicy.new(retry_on: [Carrier::RateLimit], max_attempts: 10, base: 5),
  SagaForge::RetryPolicy.new(retry_on: [Payment::Declined],  max_attempts: 1)
] do |saga, payload|
  # ...
end
```

Attempt counts and per-error budgets are tracked on the event row itself, so
they survive worker restarts and are visible when you inspect a stuck event.
Exhaustion, or an error no policy matches, marks the event `failed`; nothing
ever escapes to ActiveJob's dead-letter handling.

## Compensation

`saga.fail!(reason:)` (or an operator's `compensate!`) triggers rollback.
There is no separately maintained rollback log to drift out of sync; what is
owed is derived from the ledger. SagaForge reads this instance's `processed`
events in order, maps each through its handler's `compensate:` declaration,
removes duplicates (a `stay` loop that processed five events owes one
compensation run, not five), and runs the result last-in-first-out. Each
compensation commits individually, so a crash mid-rollback resumes exactly
where it left off. When the list drains, the saga lands in `:compensated`
(or `:cancelled`, for an operator's `cancel!`).

Compensations take no arguments because context is the snapshot: everything a
rollback needs was written by its forward block and committed atomically with
it. That leads to two conventions worth following:

- Self-guard for conditional work: `next unless saga.context[:intent_id]`.
  The guard reads what actually happened, so a compensation for work that
  never ran is a clean no-op. (Use `next`, not `return`, in these blocks.)
- Later steps should append rather than overwrite context keys that earlier
  steps' compensations read (arrays or maps for repeated values).

A step whose block failed never committed, so it owes no compensation and
left nothing in context for one to read. If its side effects did land
externally, the rule is **resume, then compensate**: fix the code, `resume!`
(the idempotent re-run commits the facts), then compensate if you still want
to. `compensate!` on an instance with failed events warns to this effect.

## Timeouts

A handler can bound how long its saga waits in a state:

```ruby
during :awaiting_settlement, on: :payment_settled,
       timeout: 30.minutes, on_timeout: :fail! do |saga, payload|
  # ...
end
```

`on_timeout:` takes `:fail!` (compensate and land in `:compensated`, with
`"timeout"` recorded as the reason) or a state name (timeout as a branch: move
on and handle it there). The clock resets on every handled event, so a `stay`
loop that is making progress is not timing out. Under the hood each commit
arms a fresh timer stamped with the saga's version; a stale timer that fires
after the saga has moved on notices the version changed and discards itself.

One operational consequence: expired timers showing up in your queue's
history are expected litter, not a leak. Volume is bounded by how often the
state handles events times the timeout duration, not by saga count.

## Operations

### Scheduling the sweeper and retention

Enqueued jobs are hints; the rows are the obligations. `SagaForge::SweeperJob`
is the delivery guarantee: it re-enqueues aged pending events (a worker
crashed between commit and enqueue), re-drives sagas stranded mid-compensation,
and re-delivers parked events whose saga is already sitting at their state.
`SagaForge::RetentionJob` prunes processed events, but only for sagas that
have reached a terminal state, because active sagas derive their rollback
plan from that history. Schedule both. With Solid Queue:

```yaml
# config/recurring.yml
saga_forge_sweeper:
  class: SagaForge::SweeperJob
  schedule: every 30 seconds
saga_forge_retention:
  class: SagaForge::RetentionJob
  schedule: every day at 4am
```

Any scheduler that can enqueue a job on a cadence works (`sidekiq-cron`,
`whenever`, plain cron). Keep the sweeper's schedule at or below
`config.sweep_interval` so nothing sits stranded longer than intended.

### Operator API

```ruby
OrderFulfillmentSaga.find_by_correlation(42)
OrderFulfillmentSaga.in_state(:awaiting_settlement)
OrderFulfillmentSaga.stalled     # instances with at least one parked event
OrderFulfillmentSaga.suspended   # instances with at least one failed event
OrderFulfillmentSaga.to_mermaid  # the compiled chain as a Mermaid diagram
```

| Call | Purpose |
| --- | --- |
| `record.history` | This instance's ledger rows, chronological. |
| `record.events.stalled` / `record.events.failed` | The parked / failed rows themselves. |
| `record.retry_stalled!` | Re-deliver parked events now, without waiting for a state change. |
| `record.resume!` | Reset failed events (attempts, budgets, error) and re-fire them, after a code fix. |
| `record.compensate!` | Run the rollback from wherever the saga currently sits. Returns `false` if there was nothing to do. |
| `record.cancel!(reason:)` | Compensate, then land in `:cancelled` instead of `:compensated`. |

`retry_stalled!` and `resume!` refuse (return `false`, log a warning) on a
terminal or already-compensating instance, since there is no live state for a
re-delivery to land against. All recovery writes are status-scoped, so racing
a live worker cannot regress an event that just processed.

### Queue adapters

SagaForge has no runtime dependency on Solid Queue; any ActiveJob adapter
works. When `SolidQueue` is loaded, the execution, compensation, and timeout
jobs opt into `limits_concurrency` keyed per saga instance, and the sweeper
and retention jobs cap themselves to one in-flight run each. That is a
throughput optimization, not a correctness requirement: every commit locks the
saga row and checks its version regardless of adapter, so concurrent or
out-of-order delivery is safe everywhere.

## Delivery guarantees

What SagaForge actually promises, so you know what to build on:

- **Events are durable from the moment of publish.** `SagaForge.publish`
  persists the ledger row before any job is enqueued; the sweeper re-delivers
  if the enqueue itself is lost. Nothing is silently dropped, and every event
  row remains queryable afterward as an audit trail.
- **Handler execution is at-least-once.** A block can run more than once for
  the same event (a crash after your API call but before the commit). Your
  external calls carry idempotency keys; SagaForge's own bookkeeping needs
  nothing from you.
- **Saga-to-saga events are exactly-once.** Staged publishes insert
  atomically with the step's commit, under deterministic ids. A re-run
  re-stages in memory only; a re-delivery after commit is a no-op. Failed
  blocks leak nothing.
- **Processing order is deterministic per instance.** Arrival order is free;
  the state chain plus parking means handlers always run in declared order.
  Across different instances and different sagas there is no ordering.
- **The saga row never lies.** `current_state` is always the true position.
  Stalls and failures are recorded on the event that stalled or failed, never
  by mutating the saga, so "stalled" and "suspended" are derived views, not
  states you can get stuck in by accident.

## Configuration

`bin/rails g saga_forge:install` generates
`config/initializers/saga_forge.rb`, which documents every option inline:

| Option | Default | What it controls |
| --- | --- | --- |
| `stall_wait` | `3.seconds` | How long an early event waits between queue spins. |
| `stall_budget` | `3` | Spins before an early event parks as `stalled`. |
| `sweep_interval` | `30.seconds` | Age at which the sweeper considers something stranded. |
| `retention` | `90.days` | Age past which processed events of terminal sagas are pruned. |
| `job_queue` | `:sagas` | ActiveJob queue for all SagaForge jobs. |
| `database` | `nil` | Named database for SagaForge's tables (see below). |
| `connects_to` | `nil` | Raw `connects_to` hash for custom roles/shards; wins over `database`. |
| `primary_key_type` | `nil` | Primary key type for SagaForge's tables (see below). |

### Primary keys

SagaForge's two tables (`saga_forge_states`, `saga_forge_events`) follow
`config.primary_key_type`: leave it `nil` to inherit your app's own default
(its `config.generators` setting, or bigint), or set it explicitly (e.g.
`:uuid`) to force a type. Correlation ids are stored as strings, so your
domain keys can be integers, UUIDs, or anything else without configuration.

### Multiple databases

To keep SagaForge's tables out of your primary database, install with a
`--database` flag:

```bash
bin/rails g saga_forge:install --database=saga_forge
```

That writes `config.database = :saga_forge` to the initializer and installs
the migration into `db/saga_forge_migrate` (not the primary `db/migrate`), so
each database keeps its own `schema_migrations`. Both models inherit from one
abstract `SagaForge::ApplicationRecord`, so `config.database` points the
whole engine at that connection. Add the database to `database.yml`:

```yaml
# config/database.yml
production:
  primary:
    <<: *default
    database: my_app_production
  saga_forge:
    <<: *default
    database: my_app_saga_forge
    migrations_paths: db/saga_forge_migrate
```

Then run `bin/rails db:migrate:saga_forge`. After a gem upgrade,
`bin/rails g saga_forge:upgrade` (no flag needed) reads `config.database`
back out of the initializer and installs any missing migrations into the
right directory. Re-running `install` with a different `--database` than last
time prompts before overwriting the initializer; pass `--force` in scripts.

For custom roles or shards, set `config.connects_to` to a hash passed
straight to Rails'
[`connects_to`](https://guides.rubyonrails.org/active_record_multiple_databases.html);
it takes precedence over `config.database`. Left unset (the default),
SagaForge stays on the app's primary connection. This is independent of where
your ActiveJob backend stores its own tables.

## Why not just chain jobs?

A workflow as "job A enqueues job B enqueues job C" works right up until it
meets production traffic. Then each gap becomes a small project:

- **Out-of-order webhooks.** The settlement webhook races your own commit and
  loses; your handler finds no order and gives up, or worse, half-processes.
  SagaForge persists the event and parks it until the saga is ready.
- **Duplicate delivery.** Webhook providers redeliver; queues are
  at-least-once. Without an idempotency key on a durable ledger, the second
  delivery double-ships the order. `event_id:` plus a unique index makes it a
  no-op.
- **Partial failure.** Payment failed after inventory was reserved. Which
  cleanup jobs do you enqueue, in what order, from what data? SagaForge
  derives the rollback from what actually committed and runs it in reverse,
  with the context each step saved for exactly this purpose.
- **Poison events.** One malformed order throws in every retry, and either
  clogs your queue's retry machinery or gets dropped by its dead-letter
  policy. SagaForge fails the event, halts just that instance, and gives you
  `suspended` plus `resume!`.
- **Ghost events.** A step publishes "order fulfilled", then fails and rolls
  back, but the downstream listener already fired. Staged publishes make that
  impossible: events surface only if the step that produced them committed.
- **"What state is order 42 in?"** With chained jobs the answer is
  archaeology across queue dashboards and log lines. Here it is a column:
  `OrderFulfillmentSaga.find_by_correlation(42).current_state`, with the full
  event history one call away.

None of these is hard on its own. Building and maintaining all of them
together, for every workflow in the app, is the work SagaForge takes off your
plate.

## SagaForge or ChronoForge?

[ChronoForge](https://github.com/radioactive-labs/chrono_forge) is the sibling
gem, and they divide the space deliberately:

| | SagaForge | ChronoForge |
| --- | --- | --- |
| Shape | Event-driven state machine | Imperative durable workflow |
| Driven by | Facts arriving from outside (webhooks, humans, other sagas) | Its own `perform` method running to completion |
| Waiting | A state parks until the event arrives | `wait_until` / `wait` polls or sleeps |
| Retry granularity | Split states | Durable steps (`durably_execute`) inside one method |
| Failure handling | Compensation: unwind committed steps in reverse | Retry/replay until the workflow completes |
| Best at | Long-lived, multi-party processes where the next step is someone else's move | Multi-step operations your app owns end to end |

Rule of thumb: if the workflow mostly waits for the outside world and needs
an unwind story, it is a saga. If it is a sequence of steps your own code
drives and should survive crashes and retries, it is a ChronoForge
workflow. They compose: a saga step that needs many resumable sub-steps kicks
off a ChronoForge workflow, and the workflow's completion publishes the event
the saga is parked on.

If you need cross-language workflow orchestration with its own control plane,
that is [Temporal](https://temporal.io)'s territory; SagaForge deliberately
stays a two-table Rails gem on your existing job backend.

## Development

After cloning, install dependencies and generate the per-Rails-version
gemfiles:

```bash
bundle install
bundle exec appraisal install   # writes gemfiles/*.gemfile
```

The default rake task runs the tests and Standard:

```bash
bundle exec rake                        # test + lint
bin/appraise                            # the full appraisal matrix
bundle exec appraisal rails-7.1 rake test   # one Rails version
DB_ADAPTER=postgresql bundle exec rake test # against PostgreSQL
```

Available appraisals: `rails-7.1`, `rails-8.0`, `rails-8.1`. CI runs the same
matrix across Ruby 3.2, 3.3, and 3.4, plus a PostgreSQL 16 lane; the
PostgreSQL lane is the one that exercises savepoint behavior SQLite cannot
reproduce, so keep it green. The full design history lives under
[`docs/superpowers/`](docs/superpowers/).

## License

SagaForge is released under the [MIT License](LICENSE).

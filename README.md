# SagaForge

Sagas for Rails on ActiveJob. A saga is a single Ruby file: a state machine
whose steps run side effects directly, commit atomically at the end of each
step, and unwind themselves in reverse order if something downstream fails.
No consumer classes, no internal command events, no held locks or open
transactions while your code runs.

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

The file **is** the state machine. `correlate_by` says how this saga finds
itself in an incoming payload; `start_with` / `during` blocks run inline —
`if`/`else` for data-driven branches, multiple `during` handlers on one event
for event-driven ones; a block that falls through advances to its state's
declared successor; `saga.fail!` halts forward progress and runs the
compensations of every step that already committed, in reverse order.
Blocks run with no lock or transaction held — atomicity comes from committing
the whole step (state + context + outbound events) in one write.

The full design, including the event ledger, parking/stalling, retry
budgets, and the schema, is in
[`docs/superpowers/specs/2026-07-19-saga-forge-design.md`](docs/superpowers/specs/2026-07-19-saga-forge-design.md).

## Installation

```bash
bundle add saga_forge
rails generate saga_forge:install
rails db:migrate
```

This writes `config/initializers/saga_forge.rb` and copies SagaForge's
migration into `db/migrate`.

### Multi-database

SagaForge can keep its two tables in their own database:

```bash
rails generate saga_forge:install --database=saga_forge
```

This sets `config.database = :saga_forge` in the initializer and installs the
migration into `db/saga_forge_migrate` instead. Add the database to
`config/database.yml` (per environment):

```yaml
saga_forge:
  <<: *default
  database: myapp_saga_forge
  migrations_paths: db/saga_forge_migrate
```

then run `bin/rails db:migrate:saga_forge`. A later `rails generate
saga_forge:migrations` re-run (e.g. after a gem upgrade) reads
`config.database` back out of the initializer, so it still targets the right
place without repeating the flag. Re-running `saga_forge:install` with a
*different* `--database` than last time changes the initializer's contents,
so Thor will prompt before overwriting it — pass `--force` in scripts.

For custom roles or shards, pass a hash straight to Rails' `connects_to` in
the initializer (it wins over `config.database`):

```ruby
SagaForge.configure do |config|
  config.connects_to = { database: { writing: :saga_forge, reading: :saga_forge } }
end
```

## The publish contract

There are two ways an event reaches a saga, and they are not interchangeable.

**`SagaForge.publish(event_name, event_id: nil, **payload)`** is the external
entry point — call it from a controller, a webhook handler, a plain
ActiveJob, anywhere *outside* saga execution. `event_id` is the producer's
idempotency key (a duplicate no-ops via a unique index; omit it and a
deterministic digest of the payload is used instead). Matching rows insert
immediately — joining whatever transaction is already open at the call site —
and `SagaForge::ExecutionJob` is enqueued for each right after. Calling it
from inside a saga block raises `SagaForge::UnstagedPublishError`.

**`saga.publish(event_name, **payload)`** is the verb available inside a
saga's own blocks (`start_with`, `during`, `compensation`). Recipients are
resolved immediately, but the rows are only *staged* in memory — the running
step's own commit inserts them, atomically with the state transition that
produced them. A block that raises, or calls `saga.fail!`, discards every
event it staged; nothing it published ever surfaces. This is what makes
"stage a publish, then fail" safe to write without a compensating delete.

## Scheduling the sweeper and retention

Enqueues are hints, not the delivery guarantee — a crashed worker or a lost
job still leaves every obligation recorded as a row. `SagaForge::SweeperJob`
re-enqueues anything stranded (aged-pending events, sagas stuck mid-
compensation, parked events whose saga has already moved on);
`SagaForge::RetentionJob` prunes processed events for sagas that have reached
a terminal state. Schedule both — with Solid Queue:

```yaml
# config/recurring.yml (Solid Queue)
saga_forge_sweeper:
  class: SagaForge::SweeperJob
  schedule: every 30 seconds
saga_forge_retention:
  class: SagaForge::RetentionJob
  schedule: every day at 4am
```

Any scheduler that can enqueue a job on a cadence works equally well
(`whenever`, `sidekiq-cron`, a plain `rake` task under cron). `config.sweep_interval`
(default 30 seconds) and `config.retention` (default 90 days) control how
aged something needs to be before the sweeper or retention job acts on it —
keep the recurring schedule at or below `sweep_interval` so nothing sits
stranded longer than intended.

## Operator API

```ruby
OrderFulfillmentSaga.find_by_correlation(42)
OrderFulfillmentSaga.in_state(:awaiting_settlement)
OrderFulfillmentSaga.stalled                # derived: has parked events
OrderFulfillmentSaga.suspended               # derived: has failed events
OrderFulfillmentSaga.to_mermaid              # chain edges solid; transition_to jumps dashed
```

| Call | Level | Purpose |
|---|---|---|
| `find_by_correlation(id)` | class | Look up the one instance for this correlation id |
| `in_state(:state)` | class | All instances currently sitting in a given state |
| `stalled` | class | Instances with at least one parked (stalled) event |
| `suspended` | class | Instances with at least one failed event |
| `to_mermaid` | class | Render the compiled chain as a Mermaid diagram |
| `record.history` | instance | This instance's ledger rows, chronological |
| `record.events.stalled` / `record.events.failed` | instance | This instance's parked / failed rows |
| `record.retry_stalled!` | instance | Re-deliver parked events now |
| `record.resume!` | instance | Reset and re-fire failed event(s), after a code fix |
| `record.compensate!(target: :compensated, reason: nil)` | instance | Run the ledger LIFO from wherever the saga currently sits |
| `record.cancel!(reason:)` | instance | `compensate!`, then land in `:cancelled` |

`retry_stalled!` and `resume!` are no-ops (return `false`, log a warning) on
a terminal or already-`:compensating` instance — there's no live state left
for a re-delivery to land against. `compensate!` warns, but still proceeds,
if failed events exist: a failed step never committed, so it implies no
compensation and left nothing in `context` for its rollback to read — fix the
code and `resume!` first if you actually want that step's compensation to
run.

## Operations notes

**Expired-timer jobs in your queue's history are expected litter, not a
leak.** Every event handled in a state that declares `timeout:` re-arms a
fresh timer at commit. The previous timer for that state, if one was armed
before, is still sitting in the queue — it fires, finds the saga's version
has moved on, and discards itself via the same version fence that powers
re-delivery. Volume is bounded by tick frequency × timeout duration, not by
saga count.

**Any ActiveJob adapter works.** SagaForge has no runtime dependency on Solid
Queue. When `SolidQueue` is loaded, `ExecutionJob`, `CompensationJob`, and
`TimeoutJob` opt into `limits_concurrency` so only one worker touches a given
saga instance at a time, and `SweeperJob`/`RetentionJob` cap themselves to one
in-flight run — this is a throughput optimization, not a correctness
requirement. Every commit re-checks the saga's version regardless of adapter,
so out-of-order or concurrent delivery is safe either way.

## Development

```bash
bundle install
bundle exec rake        # test suite + standard
```

CI runs the suite across Ruby 3.2–3.4 against the `rails-7.1`, `rails-8.0`,
and `rails-8.1` Appraisal gemfiles (SQLite) plus a dedicated PostgreSQL lane
(`bundle exec appraisal install && bin/appraise` regenerates the gemfiles
locally). The design doc and full task plan live under
[`docs/superpowers/`](docs/superpowers/).

## License

MIT.

# Forward-Only DAG + Structural Dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sagas strictly forward-only (remove `stay`, reject self/backward transitions), replace the caller-supplied `event_id` idempotency key with a structural `(saga_class, correlation_id, event_name)` dedup key, and persist the derived-but-monotonic facts (`finalized_at`, `last_active_at`, `last_processed_at`) so sweepers/retention/dashboard query SQL instead of constantizing definitions.

**Architecture:** Removing `stay` makes "one event name per saga instance" the rule, which lets `(saga_class, correlation_id, event_name)` become the unique dedup key — so `event_id`, `digest_id`, and staged-id namespacing all disappear, and duplicate deliveries (external webhooks *and* saga-to-saga fan-in) dedup for free at the index instead of leaking orphaned `stalled` rows. Forward-only is enforced at runtime by rejecting any `transition_to` whose target is a state the saga has already resided in (derived from the processed-event ledger; no new column). Staged inserts, now able to collide benignly, are wrapped in per-row savepoints. Three nullable timestamps are written atomically in the same commits that already write `current_state`/`processed`, so they can never drift.

**Tech Stack:** Ruby, ActiveRecord, ActiveJob, Minitest + Combustion (dummy app under `test/internal`), Solid Queue (optional, concurrency limits only).

**User Verification:** NO — no user verification required (this is an engineering change; correctness is verified by the test suite).

---

## Conventions

- **Full suite:** `bundle exec rake test`
- **One file:** `bundle exec ruby -Itest test/<name>_test.rb`
- **One test:** `bundle exec ruby -Itest test/<name>_test.rb -n "/pattern/"`
- **Lint:** `bundle exec standardrb` (runs as part of `rake default`)
- The gem is **unreleased** — original migrations are edited in place; there is no upgrade migration and no data backfill.
- CLAUDE.md rules in force: inline indexes/constraints in the `create_table` block; `Rails.logger.<level> { "..." }` block form; no gratuitous `respond_to?` defensiveness.

## File Structure

**Schema / models**
- `lib/generators/saga_forge/templates/install_saga_forge.rb` — canonical migration (edited in place)
- `test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb` — dummy-app mirror (kept in sync)
- `lib/saga_forge/event.rb`, `lib/saga_forge/state.rb` — scopes/derivations

**Publish path**
- `lib/saga_forge.rb` — `publish` signature, `ForwardOnlyError`
- `lib/saga_forge/publisher.rb` — structural dedup, drop `digest_id`
- `lib/saga_forge/router.rb` — unchanged attrs (already no `event_id`)
- `lib/saga_forge/execution/facade.rb` — drop `stay`, drop staged-id namespacing
- `lib/saga_forge/execution/compensation_facade.rb` — drop staged-id namespacing

**Execution**
- `lib/saga_forge/execution/runner.rb` — remove `:stay`, forward-only guard, tolerant staged inserts, timestamps
- `lib/saga_forge/compensation_runner.rb` — tolerant staged inserts, timestamps
- `lib/saga_forge/definition.rb` — remove `stay_targets` + stay graph edges
- `lib/saga_forge/dashboard/graph.rb` — comment only

**Jobs / recovery**
- `lib/saga_forge/sweeper_job.rb` — compensating sweep keys off `last_active_at`
- `lib/saga_forge/retention_job.rb` — keys off `last_processed_at` + `finalized_at`
- `lib/saga_forge/configuration.rb` — `stall_budget` default

**Dashboard**
- `saga_forge-dashboard/app/.../*` — `finalized` scope/filter, drop a constantize

**Docs / fixtures / tests**
- `README.md`, `docs/superpowers/specs/2026-07-19-saga-forge-design.md`, `lib/generators/saga_forge/templates/initializer.rb`
- `test/internal/app/sagas/*.rb` — rewrite `stay`-based fixtures
- `test/*_test.rb` — adapt

---

### Task 1: Reduce `stall_budget` default

**Goal:** Lower the early-event spin budget from 40 (~2 min) to 3 (~9s), since parking is cheap and self-heals via redelivery.

**Files:**
- Modify: `lib/saga_forge/configuration.rb:8`
- Modify: `lib/generators/saga_forge/templates/initializer.rb:13`
- Modify: `README.md` (lines referencing `40`)
- Test: `test/configuration_test.rb`

**Acceptance Criteria:**
- [ ] `SagaForge.config.stall_budget == 3` by default
- [ ] `stall_wait` unchanged at `3.seconds`
- [ ] Docs no longer claim `40`

**Verify:** `bundle exec ruby -Itest test/configuration_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Update the failing expectation**

In `test/configuration_test.rb`, find the assertion on `stall_budget` (currently expects `40`) and change it to `3`. If none exists, add:

```ruby
def test_default_stall_budget_is_small
  assert_equal 3, SagaForge.config.stall_budget
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/configuration_test.rb -n "/stall_budget/"`
Expected: FAIL (got 40, expected 3)

- [ ] **Step 3: Change the default**

`lib/saga_forge/configuration.rb:8`:

```ruby
      @stall_budget = 3
```

- [ ] **Step 4: Update docs**

`lib/generators/saga_forge/templates/initializer.rb:13`:

```ruby
  # config.stall_budget   = 3           # spins before an event parks as stalled
```

In `README.md`, update the three references (the config table row, the "default 40 by 3" prose, and the "raise `config.stall_budget`" guidance) to say `3` and "~9s"; keep the guidance that a genuinely slow upstream can raise it.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/configuration_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/saga_forge/configuration.rb lib/generators/saga_forge/templates/initializer.rb README.md test/configuration_test.rb
git commit -m "feat(config): lower stall_budget default to 3 (parking is cheap and self-healing)"
```

```json:metadata
{"files": ["lib/saga_forge/configuration.rb", "lib/generators/saga_forge/templates/initializer.rb", "README.md", "test/configuration_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/configuration_test.rb", "acceptanceCriteria": ["stall_budget default is 3", "docs updated"], "requiresUserVerification": false}
```

---

### Task 2: Schema — structural dedup key + persisted timestamps

**Goal:** Drop `event_id` and its unique index; add a unique index on `(saga_class, correlation_id, event_name)`; add `finalized_at` + `last_active_at` to states and `last_processed_at` to events. Edit the original migration in place (unreleased) and fix the dummy app.

**Files:**
- Modify: `lib/generators/saga_forge/templates/install_saga_forge.rb`
- Modify: `test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb`
- Test: `test/schema_test.rb`

**Acceptance Criteria:**
- [ ] `saga_forge_events` has no `event_id` column and a unique index on `[saga_class, correlation_id, event_name]`
- [ ] `saga_forge_events` has `last_processed_at` (datetime, null)
- [ ] `saga_forge_states` has `finalized_at` and `last_active_at` (datetime, null) and an index on `finalized_at`
- [ ] Dummy app schema matches the template; suite boots

**Verify:** `bundle exec ruby -Itest test/schema_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Update `schema_test.rb` expectations first**

Open `test/schema_test.rb`. Change assertions so they (a) assert `saga_forge_events` columns do **not** include `event_id` and **do** include `last_processed_at`; (b) assert a unique index on `%w[saga_class correlation_id event_name]` exists and the old `%w[event_id saga_class]` unique index does not; (c) assert `saga_forge_states` includes `finalized_at` and `last_active_at`. Follow the file's existing assertion style (it introspects `connection.columns` / `connection.indexes`).

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -Itest test/schema_test.rb`
Expected: FAIL (event_id still present / new columns missing)

- [ ] **Step 3: Edit the canonical migration**

`lib/generators/saga_forge/templates/install_saga_forge.rb` — states table: add the two datetime columns and an index, immediately after the `t.timestamps` line and alongside the existing indexes (inline per CLAUDE.md):

```ruby
      t.datetime :finalized_at
      t.datetime :last_active_at

      t.timestamps

      t.index %i[saga_class correlation_id], unique: true
      t.index %i[saga_class current_state]
      # Plain (non-partial, adapter-portable) index: the sweeper's stranded-
      # compensating scan filters current_state cross-class, which neither
      # of the above compound indexes serves.
      t.index :current_state
      # Retention/dashboard filter finalized vs active in SQL (finalized_at
      # IS [NOT] NULL) without loading each saga class to ask terminal?.
      t.index :finalized_at
```

Events table: remove the `event_id` column and its unique index; add `last_processed_at` and the structural unique index:

```ruby
    create_table :saga_forge_events, id: primary_key_type do |t|
      t.string :saga_class, null: false
      t.string :correlation_id, null: false
      t.references :saga_forge_state, type: foreign_key_type,
        foreign_key: {to_table: :saga_forge_states}, index: false

      t.string :event_name, null: false
      t.integer :status, null: false, default: 0
      t.integer :stall_count, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :last_processed_at

      if t.respond_to?(:jsonb)
        t.jsonb :payload, null: false, default: {}
        t.jsonb :retry_budgets, null: false, default: {}
        t.jsonb :error
      else
        t.json :payload, null: false, default: {}
        t.json :retry_budgets, null: false, default: {}
        t.json :error
      end

      t.timestamps

      # Structural idempotency: a saga instance handles each event name at
      # most once (forward-only, no stay), so this tuple IS the dedup key —
      # webhook redeliveries and saga-to-saga fan-in no-op at the index.
      t.index %i[saga_class correlation_id event_name], unique: true
      t.index %i[saga_class correlation_id status]
      t.index %i[status created_at]
      t.index %i[saga_forge_state_id created_at]
    end
```

- [ ] **Step 4: Mirror into the dummy app migration**

Apply the identical column/index edits to `test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb` (keep the "in sync with the template" comment).

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec ruby -Itest test/schema_test.rb`
Expected: PASS

Then boot-check the suite loads: `bundle exec ruby -Itest test/models_test.rb`
Expected: PASS (or only failures tied to later tasks — note them, don't fix here).

- [ ] **Step 6: Commit**

```bash
git add lib/generators/saga_forge/templates/install_saga_forge.rb test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb test/schema_test.rb
git commit -m "feat(schema): structural dedup key + finalized_at/last_active_at/last_processed_at"
```

```json:metadata
{"files": ["lib/generators/saga_forge/templates/install_saga_forge.rb", "test/internal/db/migrate/20260719000001_create_saga_forge_tables.rb", "test/schema_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/schema_test.rb", "acceptanceCriteria": ["event_id dropped", "structural unique index", "three new timestamp columns"], "requiresUserVerification": false}
```

---

### Task 3: Structural dedup in the publish path

**Goal:** Remove the `event_id`/`digest_id` machinery. External and saga-to-saga publishes build rows without `event_id`; dedup is entirely the structural unique index.

**Files:**
- Modify: `lib/saga_forge.rb:46-48`
- Modify: `lib/saga_forge/publisher.rb`
- Modify: `lib/saga_forge/execution/facade.rb:48-55`
- Modify: `lib/saga_forge/execution/compensation_facade.rb:17-22`
- Test: `test/publisher_test.rb`

**Acceptance Criteria:**
- [ ] `SagaForge.publish(:evt, **payload)` — no `event_id:` param
- [ ] Duplicate external delivery of the same `(saga_class, correlation_id, event_name)` inserts one row
- [ ] `digest_id` and all `event_id` merges are gone
- [ ] `saga.publish` / compensation `publish` stage rows without an `event_id` key

**Verify:** `bundle exec ruby -Itest test/publisher_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Update publisher tests**

In `test/publisher_test.rb`: delete tests asserting `event_id:`/digest behavior; add/adjust to assert structural dedup:

```ruby
def test_duplicate_delivery_dedups_on_structural_key
  2.times { SagaForge.publish(:order_placed, order_id: "A1") }
  rows = SagaForge::Event.where(saga_class: "OrderSaga", correlation_id: "A1", event_name: "order_placed")
  assert_equal 1, rows.count
end
```

(Use whatever fixture saga already handles the event in this file; keep the file's existing setup.)

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -Itest test/publisher_test.rb`
Expected: FAIL (`unknown keyword: :event_id` or dup rows)

- [ ] **Step 3: Drop `event_id` from the public API**

`lib/saga_forge.rb:46-48`:

```ruby
    def publish(event_name, **payload)
      Publisher.publish(event_name, payload: payload)
    end
```

- [ ] **Step 4: Structural Publisher**

Rewrite `lib/saga_forge/publisher.rb` — remove `event_id`/`digest_id`/`deep_sort`; keep the savepoint insert (it already tolerates `RecordNotUnique`):

```ruby
module SagaForge
  # The external entry point: INSERTs join any open transaction on the
  # engine connection; enqueues happen right after in plain code. The pending
  # row is the obligation, the enqueue a hint, the sweeper the guarantee.
  #
  # Idempotency is structural: the (saga_class, correlation_id, event_name)
  # unique index no-ops a duplicate delivery. A forward-only saga handles each
  # event name at most once, so a second delivery is always a duplicate.
  class Publisher
    class << self
      def publish(event_name, payload:)
        if SagaForge.within_saga_execution?
          raise UnstagedPublishError,
            "SagaForge.publish called inside saga execution — use saga.publish (staged, delivered on commit)"
        end

        attrs_list = Router.resolve(event_name, payload)
        return [] if attrs_list.empty?

        rows = attrs_list.filter_map { |attrs| insert_row(attrs) }
        rows.each { |row| ExecutionJob.perform_later(row.id) }
        rows
      end

      private

      # On Postgres, a failed INSERT (the unique-index violation) poisons the
      # server-side transaction — every subsequent statement, including the
      # caller's own COMMIT, would fail. The savepoint survives that abort for
      # the no-op'd duplicate; it nests inside whatever transaction is already
      # open and rolls back with its parent. The spec's "inserts join the
      # caller's transaction" guarantee holds: a successful insert still lives
      # and dies with the ambient transaction.
      def insert_row(attrs)
        ApplicationRecord.transaction(requires_new: true) do
          Event.create!(attrs)
        end
      rescue ActiveRecord::RecordNotUnique
        nil # duplicate delivery — the structural unique index no-ops it
      end
    end
  end
end
```

- [ ] **Step 5: Drop staged-id namespacing**

`lib/saga_forge/execution/facade.rb` — `publish` no longer merges an `event_id`; `@source_event_id`/`@publish_seq` become unnecessary for id-building (keep `source_event_id` in the initializer only if other code reads it — it does not; remove it):

```ruby
      def publish(event_name, **payload)
        @staged_publishes.concat(Router.resolve(event_name, payload))
        nil
      end
```

Remove `source_event_id:` from `Facade#initialize` and the `@source_event_id`/`@publish_seq` instance vars. Update the block comment above `publish` (it references §A.2 staging — keep that; drop the id-namespacing sentence).

`lib/saga_forge/execution/compensation_facade.rb` — same; drop `id_prefix:` and `@publish_seq`:

```ruby
    class CompensationFacade
      attr_reader :correlation_id, :current_state, :context, :staged_publishes

      def initialize(correlation_id:, current_state:, context:)
        @correlation_id = correlation_id
        @current_state = current_state
        @context = context
        @staged_publishes = []
      end

      def publish(event_name, **payload)
        @staged_publishes.concat(Router.resolve(event_name, payload))
        nil
      end
    end
```

> NOTE: The call sites in `runner.rb` (`Facade.new(... source_event_id: event.id)`) and `compensation_runner.rb` (`CompensationFacade.new(... id_prefix: ...)`) are updated in **Task 4** and **Task 5** respectively where those files are already open; this task leaves those two `.new` calls temporarily passing the now-ignored kwarg only if you run the suite mid-task. To keep this task green on its own, also delete the `source_event_id:`/`id_prefix:` arguments from those two call sites now (one line each) — they are covered again later.

- [ ] **Step 6: Run to verify it passes**

Run: `bundle exec ruby -Itest test/publisher_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/saga_forge.rb lib/saga_forge/publisher.rb lib/saga_forge/execution/facade.rb lib/saga_forge/execution/compensation_facade.rb lib/saga_forge/execution/runner.rb lib/saga_forge/compensation_runner.rb test/publisher_test.rb
git commit -m "feat(publish): structural (saga,correlation,event) dedup; drop event_id/digest"
```

```json:metadata
{"files": ["lib/saga_forge.rb", "lib/saga_forge/publisher.rb", "lib/saga_forge/execution/facade.rb", "lib/saga_forge/execution/compensation_facade.rb"], "verifyCommand": "bundle exec ruby -Itest test/publisher_test.rb", "acceptanceCriteria": ["no event_id param", "structural dedup", "digest_id gone"], "requiresUserVerification": false}
```

---

### Task 4: Tolerant staged inserts (fan-in dedup)

**Goal:** Staged inserts in the commit path can now collide benignly (two producers → same recipient event). Wrap each in a savepoint and skip `RecordNotUnique`, replacing the old "must raise" invariant. Also updates the two `.new` call sites from Task 3.

**Files:**
- Modify: `lib/saga_forge/execution/runner.rb:146-196` (`commit!`) and `:61-72` (`Facade.new`)
- Modify: `lib/saga_forge/compensation_runner.rb:52-95` (`run_one`)
- Test: `test/execution_commit_test.rb`, `test/compensation_test.rb`

**Acceptance Criteria:**
- [ ] Two sagas publishing the same event to the same recipient produce exactly one recipient row (no orphaned `stalled` duplicate)
- [ ] A non-`RecordNotUnique` error during staged insert still raises
- [ ] `Facade.new` no longer passes `source_event_id:`

**Verify:** `bundle exec ruby -Itest test/execution_commit_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the failing fan-in test**

In `test/execution_commit_test.rb`, add a test where two distinct saga instances each `saga.publish` the same event to one recipient correlation, then assert the recipient has one row. Use existing fixtures if a publisher/recipient pair exists; otherwise add minimal fixtures under `test/internal/app/sagas/`. Assert:

```ruby
def test_staged_fan_in_dedups_to_one_recipient_row
  # drive two producer commits that both stage :ready for recipient "R1"
  # ... (fixture-specific setup) ...
  rows = SagaForge::Event.where(saga_class: "RecipientSaga", correlation_id: "R1", event_name: "ready")
  assert_equal 1, rows.count
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -Itest test/execution_commit_test.rb`
Expected: FAIL (RecordNotUnique raised out of commit, or two rows)

- [ ] **Step 3: Tolerant staged insert in `commit!`**

`lib/saga_forge/execution/runner.rb` — in `execute!`, update the facade construction (drop `source_event_id:`):

```ruby
        facade = Facade.new(
          definition: definition,
          correlation_id: event.correlation_id,
          current_state: current,
          context: context
        )
```

In `commit!`, replace the staged-insert line and its comment block:

```ruby
          unless failing # fail! discards staged publishes (§A.1)
            # Staged rows can collide benignly now that dedup is structural:
            # two producers publishing the same event to the same recipient,
            # or a redelivery, hit the (saga,correlation,event) unique index.
            # Each insert gets its own savepoint so a duplicate rolls back to
            # the savepoint instead of poisoning this commit's transaction
            # (Postgres abort-on-error), exactly as Publisher#insert_row does.
            @inserted_rows = facade.staged_publishes.filter_map do |attrs|
              ApplicationRecord.transaction(requires_new: true) { Event.create!(attrs) }
            rescue ActiveRecord::RecordNotUnique
              nil
            end
          end
```

- [ ] **Step 4: Tolerant staged insert in `CompensationRunner#run_one`**

`lib/saga_forge/compensation_runner.rb` — update `CompensationFacade.new` (drop `id_prefix:`):

```ruby
      facade = Execution::CompensationFacade.new(
        correlation_id: state.correlation_id,
        current_state: state.current_state,
        context: context
      )
```

Replace the staged-insert line (`:91`) and its comment:

```ruby
        # Same savepoint-per-row tolerance as Runner#commit!: a compensation
        # publishing to a recipient that already has that event no-ops at the
        # structural unique index instead of aborting this commit.
        inserted = facade.staged_publishes.filter_map do |attrs|
          ApplicationRecord.transaction(requires_new: true) { Event.create!(attrs) }
        rescue ActiveRecord::RecordNotUnique
          nil
        end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec ruby -Itest test/execution_commit_test.rb test/compensation_test.rb`
Expected: PASS (compensation may still fail on stay-fixture issues resolved in Task 5 — if so, note and proceed).

- [ ] **Step 6: Commit**

```bash
git add lib/saga_forge/execution/runner.rb lib/saga_forge/compensation_runner.rb test/execution_commit_test.rb
git commit -m "feat(commit): tolerate benign staged-insert collisions via per-row savepoints"
```

```json:metadata
{"files": ["lib/saga_forge/execution/runner.rb", "lib/saga_forge/compensation_runner.rb", "test/execution_commit_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/execution_commit_test.rb", "acceptanceCriteria": ["fan-in dedups to one row", "non-dup errors still raise"], "requiresUserVerification": false}
```

---

### Task 5: Remove `stay`

**Goal:** Delete the `stay` verb and all its machinery; rewrite the three `stay`-based test fixtures as forward-only sagas and adapt their tests.

**Files:**
- Modify: `lib/saga_forge/execution/facade.rb:31-38` (delete `stay`), `:6-11` (comment)
- Modify: `lib/saga_forge/execution/runner.rb:198-205` (`resolve_next_state` — drop `:stay`)
- Modify: `lib/saga_forge/definition.rb:118-124` (`stay_targets`), `:154-156` (graph edges), `:126` and `:165` (comments)
- Modify: `lib/saga_forge/dashboard/graph.rb:15` (comment)
- Rewrite: `test/internal/app/sagas/stay_saga.rb`, `pack_saga.rb`, `stay_timeout_saga.rb`
- Test: `test/saga_flow_test.rb`, `test/compensation_test.rb`, `test/definition_graph_test.rb`, `test/timeout_test.rb`

**Acceptance Criteria:**
- [ ] `Facade` has no `stay`; `resolve_next_state` has no `:stay` case
- [ ] `Definition#to_graph` emits no `:stay` edges; `stay_targets` is gone
- [ ] No fixture calls `saga.stay`; suite is green (except Task 6 DAG tests)

**Verify:** `bundle exec ruby -Itest test/saga_flow_test.rb test/definition_graph_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Rewrite fixtures forward-only**

`test/internal/app/sagas/pack_saga.rb` — advance instead of loop; keep the compensation and the failure branch (compensation dedup is now exercised by two events sharing `:unpack`, not by a loop):

```ruby
class PackSaga < SagaForge::Base
  correlate_by :box_id
  start_with(:pack_started) { |saga, _payload| saga.context[:items] = 0 }
  during(:packing, on: :item_packed, compensate: :unpack) do |saga, _payload|
    saga.context[:items] = saga.context[:items].to_i + 1
  end
  during(:sealing, on: :box_sealed, compensate: :unpack) { |saga, _payload| saga.context[:sealed] = true }
  during(:packing, on: :audit_failed) { |saga, _payload| saga.fail! reason: "audit" }
  finish_with :packed
  compensation(:unpack) { |saga| saga.context[:unpack_runs] = saga.context[:unpack_runs].to_i + 1 }
end
```

`test/internal/app/sagas/stay_saga.rb` — replace the counting loop with a two-step forward saga (or delete the file if `saga_flow_test` no longer references it — see Step 3):

```ruby
class StaySaga < SagaForge::Base
  correlate_by :counter_id
  start_with(:start_counting) { |saga, _payload| saga.context[:n] = 0 }
  during(:counting, on: :tick) { |saga, _payload| saga.context[:n] = saga.context[:n].to_i + 1 }
  finish_with :done_counting
end
```

`test/internal/app/sagas/stay_timeout_saga.rb` — timeout on a normal awaiting state:

```ruby
class StayTimeoutSaga < SagaForge::Base
  correlate_by :id
  start_with(:st_started) { |saga, _payload| }
  during(:st_waiting, on: :st_tick, timeout: 10.minutes, on_timeout: :fail!) { |saga, _payload| }
  finish_with :st_done
end
```

- [ ] **Step 2: Delete `stay` from the engine**

`lib/saga_forge/execution/facade.rb` — delete the `stay` method (`:31-38`); update the class comment (`:6-11`) to drop the "stay then transition_to" example.

`lib/saga_forge/execution/runner.rb` `resolve_next_state`:

```ruby
      def resolve_next_state(definition, current, outcome)
        case outcome
        in nil then definition.successor_of(current).to_s
        in [:transition_to, target] then target.to_s
        in [:fail, _] then State::COMPENSATING.to_s
        end
      end
```

`lib/saga_forge/definition.rb` — delete `stay_targets` (`:118-124`); in `to_graph` delete the `stay_targets.each { ... }` block (`:154-156`); update the `to_graph` doc comment (`:126`) and the `scan_handlers` comment (`:165`) to drop "stay".

`lib/saga_forge/dashboard/graph.rb:15` — remove `| :stay (best-effort self-loop)` from the edge-kind comment.

- [ ] **Step 3: Adapt tests**

Read each of `test/saga_flow_test.rb`, `test/compensation_test.rb`, `test/definition_graph_test.rb`, `test/timeout_test.rb`. Replace `stay`-dependent assertions:
- **saga_flow_test:** any test asserting a saga loops in a state via `stay` — rewrite to assert forward advance through the new fixtures (e.g. `StaySaga` reaching `:done_counting` after one `tick`).
- **compensation_test:** the "N `item_packed` → one `unpack`" dedup test — rewrite so `PackSaga` processes `item_packed` then `box_sealed` (both `compensate: :unpack`) and assert `unpack_runs == 1` after `fail!`/`compensate!` (still proves dedup-to-distinct-handlers, now via shared handler across two events).
- **definition_graph_test:** delete assertions expecting a `:stay` self-edge; assert the forward chain/jump edges only.
- **timeout_test:** rewrite the `StayTimeoutSaga` loop-timeout test to assert timeout fires on `:st_waiting` when no `st_tick` arrives.

- [ ] **Step 4: Run to verify**

Run: `bundle exec ruby -Itest test/saga_flow_test.rb test/compensation_test.rb test/definition_graph_test.rb test/timeout_test.rb`
Expected: PASS (self-transition rejection is added in Task 6; do not add those assertions here).

- [ ] **Step 5: Commit**

```bash
git add lib/saga_forge/execution/facade.rb lib/saga_forge/execution/runner.rb lib/saga_forge/definition.rb lib/saga_forge/dashboard/graph.rb test/internal/app/sagas/ test/saga_flow_test.rb test/compensation_test.rb test/definition_graph_test.rb test/timeout_test.rb
git commit -m "feat!: remove stay verb; sagas advance, branch, or fail — never loop"
```

```json:metadata
{"files": ["lib/saga_forge/execution/facade.rb", "lib/saga_forge/execution/runner.rb", "lib/saga_forge/definition.rb", "lib/saga_forge/dashboard/graph.rb", "test/internal/app/sagas/pack_saga.rb", "test/internal/app/sagas/stay_saga.rb", "test/internal/app/sagas/stay_timeout_saga.rb"], "verifyCommand": "bundle exec ruby -Itest test/saga_flow_test.rb test/definition_graph_test.rb", "acceptanceCriteria": ["stay removed everywhere", "fixtures forward-only", "graph has no stay edges"], "requiresUserVerification": false}
```

---

### Task 6: Forward-only DAG enforcement

**Goal:** Reject any `transition_to` whose target is a state the saga has already resided in (subsumes self-transition; rejects backward jumps; allows skip-ahead and rejoin). Derived from the processed ledger — no new column.

**Files:**
- Modify: `lib/saga_forge.rb` (add `ForwardOnlyError`)
- Modify: `lib/saga_forge/execution/runner.rb` (`commit!` guard, `execute!` rescue)
- Test: `test/execution_lifecycle_test.rb` (or `test/saga_flow_test.rb`)
- Fixtures: `test/internal/app/sagas/` (add a saga with a backward `transition_to` and one with a legit skip/rejoin)

**Acceptance Criteria:**
- [ ] `transition_to(current_state)` → event `failed` with `ForwardOnlyError`, saga row untouched, no retry-budget consumed
- [ ] `transition_to(an already-visited earlier state)` → same
- [ ] Skip-ahead `transition_to(a later, unvisited state)` → succeeds
- [ ] Rejoin (`transition_to` a not-yet-visited mainline state from a detour) → succeeds

**Verify:** `bundle exec ruby -Itest test/execution_lifecycle_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Add fixtures**

`test/internal/app/sagas/backward_saga.rb`:

```ruby
class BackwardSaga < SagaForge::Base
  correlate_by :id
  start_with(:bw_started) { |saga, _payload| }
  during(:step_a, on: :go_a) { |saga, _payload| }
  during(:step_b, on: :go_b) { |saga, _payload| saga.transition_to(:step_a) } # illegal: step_a already visited
  finish_with :bw_done
end
```

`test/internal/app/sagas/rejoin_saga.rb`:

```ruby
class RejoinSaga < SagaForge::Base
  correlate_by :id
  start_with(:rj_started) { |saga, _payload| }
  during(:branch_point, on: :decide) do |saga, payload|
    saga.transition_to(:detour) if payload[:take_detour]
  end
  during(:mainline, on: :proceed) { |saga, _payload| }
  during(:detour, on: :detour_done) { |saga, _payload| saga.transition_to(:mainline) } # legal: mainline not visited
  finish_with :rj_done
end
```

(Chain order: `branch_point → mainline → detour` by declaration; `detour → mainline` is a rejoin to an unvisited state, so it must be allowed.)

- [ ] **Step 2: Write failing tests**

In `test/execution_lifecycle_test.rb`:

```ruby
def test_self_transition_is_rejected
  # drive StaySaga's :counting handler to call transition_to(:counting)
  # via a one-off fixture, or use a saga whose handler self-transitions.
  # Assert the source event is :failed and current_state is unchanged.
end

def test_backward_transition_is_rejected
  SagaForge.publish(:bw_started, id: "b1"); drain
  SagaForge.publish(:go_a, id: "b1"); drain
  SagaForge.publish(:go_b, id: "b1"); drain
  evt = SagaForge::Event.find_by(saga_class: "BackwardSaga", correlation_id: "b1", event_name: "go_b")
  assert evt.failed?
  assert_equal "ForwardOnlyError", evt.error["class"]
  assert_equal "step_b", SagaForge::State.find_by(saga_class: "BackwardSaga", correlation_id: "b1").current_state
end

def test_rejoin_to_unvisited_state_is_allowed
  SagaForge.publish(:rj_started, id: "r1"); drain
  SagaForge.publish(:decide, id: "r1", take_detour: true); drain
  SagaForge.publish(:detour_done, id: "r1"); drain
  assert_equal "mainline", SagaForge::State.find_by(saga_class: "RejoinSaga", correlation_id: "r1").current_state
end
```

Use the file's existing job-draining helper (`perform_enqueued_jobs`/`drain`) — match its convention.

- [ ] **Step 3: Run to verify it fails**

Run: `bundle exec ruby -Itest test/execution_lifecycle_test.rb`
Expected: FAIL (backward transition currently commits)

- [ ] **Step 4: Add the error class**

`lib/saga_forge.rb`, in the runtime-errors group:

```ruby
  class ForwardOnlyError < Error; end # transition_to re-enters a visited state
```

- [ ] **Step 5: Guard in the Runner**

`lib/saga_forge/execution/runner.rb` — in `commit!`, right after `next_state = resolve_next_state(...)` and before `@inserted_rows = []`/`State.transaction`:

```ruby
        if facade.outcome.is_a?(Array) && facade.outcome.first == :transition_to
          guard_forward_only!(definition, current, next_state)
        end
```

Add the private method (visited = processed events' states plus the current state; a valid forward move never targets a visited state):

```ruby
      # Forward-only: a saga never re-enters a state it has resided in, so it
      # handles each event name at most once (the invariant the structural
      # dedup index relies on). Visited states are derived from the ledger —
      # every processed event's registered state — plus the state we're in
      # now. Self- and backward-transitions are the two ways to violate it.
      def guard_forward_only!(definition, current, next_state)
        visited = Event.processed
          .for_instance(event.saga_class, event.correlation_id)
          .pluck(:event_name)
          .filter_map { |name| definition.state_for_event(name)&.to_s }
        visited << current.to_s
        return unless visited.include?(next_state)
        raise ForwardOnlyError,
          "#{event.saga_class}##{event.correlation_id}: transition to #{next_state} re-enters a visited state — sagas are forward-only"
      end
```

In `execute!`, add a rescue AFTER the block's `begin/rescue` and at the method level alongside `rescue ConcurrencyConflict`:

```ruby
        state_row = commit!(definition, state_row, current, entry_version, facade)
        after_commit_effects(definition, state_row, facade)
        [:done]
      rescue ConcurrencyConflict
        [:retry, SagaForge.config.stall_wait]
      rescue ForwardOnlyError => e
        record_forward_violation(e)
        [:done]
      end
```

Add the recorder (a forward violation is a programming bug — poison-pill the event immediately, no retry budget, saga row untouched; operator fixes the target and `resume!`s):

```ruby
      def record_forward_violation(error)
        event.update!(status: :failed, error: {
          "class" => error.class.name,
          "message" => SagaForge.safe_error_message(error.message, ERROR_MESSAGE_LIMIT)
        })
        Rails.logger.error { "[saga_forge] #{event.saga_class}##{event.correlation_id} #{event.event_name} rejected: #{error.message}" }
      end
```

- [ ] **Step 6: Run to verify it passes**

Run: `bundle exec ruby -Itest test/execution_lifecycle_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/saga_forge.rb lib/saga_forge/execution/runner.rb test/internal/app/sagas/backward_saga.rb test/internal/app/sagas/rejoin_saga.rb test/execution_lifecycle_test.rb
git commit -m "feat!: enforce forward-only DAG — reject transitions into visited states"
```

```json:metadata
{"files": ["lib/saga_forge.rb", "lib/saga_forge/execution/runner.rb", "test/internal/app/sagas/backward_saga.rb", "test/internal/app/sagas/rejoin_saga.rb", "test/execution_lifecycle_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/execution_lifecycle_test.rb", "acceptanceCriteria": ["self+backward rejected as failed", "skip-ahead and rejoin allowed", "no retry budget consumed"], "requiresUserVerification": false}
```

---

### Task 7: Persisted timestamps wiring

**Goal:** Write `last_active_at`, `finalized_at`, `last_processed_at` atomically in the commits that already write `current_state`/`processed`, so they never drift.

**Files:**
- Modify: `lib/saga_forge/execution/runner.rb` (`commit!`, `discard_terminal!`)
- Modify: `lib/saga_forge/compensation_runner.rb` (`run_one` commit, `finalize!`)
- Test: `test/execution_commit_test.rb`, `test/compensation_test.rb`

**Acceptance Criteria:**
- [ ] After a normal commit, the state's `last_active_at` is set and the processed event's `last_processed_at` is set
- [ ] Reaching a terminal state (forward `finish_with`, `transition_to` terminal, or compensation `finalize!`) sets `finalized_at`
- [ ] A non-terminal commit leaves `finalized_at` nil
- [ ] A compensation step commit updates `last_active_at`

**Verify:** `bundle exec ruby -Itest test/execution_commit_test.rb test/compensation_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests**

In `test/execution_commit_test.rb`:

```ruby
def test_commit_stamps_activity_and_processed_timestamps
  # drive one successful event; assert state.last_active_at present,
  # event.last_processed_at present, and (non-terminal) state.finalized_at nil.
end

def test_reaching_terminal_stamps_finalized_at
  # drive a saga to finish_with; assert state.finalized_at present.
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -Itest test/execution_commit_test.rb -n "/timestamp|finalized/"`
Expected: FAIL (columns nil)

- [ ] **Step 3: Stamp in `Runner#commit!`**

In the `State.transaction` block, update the two writes:

```ruby
          now = Time.current
          finalized = definition.terminal?(next_state.to_sym) ? now : nil
          state_row.update!(
            current_state: next_state, version: entry_version + 1, context: context,
            last_active_at: now, finalized_at: finalized
          )
          event.update!(status: :processed, saga_forge_state_id: state_row.id, error: nil, last_processed_at: now)
```

For the `State.create!` (nil state_row) branch, no change is needed — the subsequent `update!` above runs in the same transaction and stamps it.

In `discard_terminal!`:

```ruby
      def discard_terminal!(current)
        event.update!(status: :processed, last_processed_at: Time.current, error: {"discarded" => "terminal state #{current}"})
        Rails.logger.info { "[saga_forge] discarded #{event.event_name} for terminal #{event.saga_class}##{event.correlation_id}" }
        [:done]
      end
```

- [ ] **Step 4: Stamp in `CompensationRunner`**

In `run_one`'s `state.update!` (the committed-progress write):

```ruby
        state.update!(context: committed, version: state.version + 1, last_active_at: Time.current)
```

In `finalize!`:

```ruby
      def finalize!
        state.with_lock do
          target = state.context.dig("__saga_forge", "target") || "compensated"
          now = Time.current
          state.update!(current_state: target, version: state.version + 1, finalized_at: now, last_active_at: now)
        end
        [:done]
      end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec ruby -Itest test/execution_commit_test.rb test/compensation_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/saga_forge/execution/runner.rb lib/saga_forge/compensation_runner.rb test/execution_commit_test.rb test/compensation_test.rb
git commit -m "feat: stamp last_active_at/finalized_at/last_processed_at atomically at commit"
```

```json:metadata
{"files": ["lib/saga_forge/execution/runner.rb", "lib/saga_forge/compensation_runner.rb", "test/execution_commit_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/execution_commit_test.rb test/compensation_test.rb", "acceptanceCriteria": ["timestamps stamped in-commit", "finalized_at only on terminal"], "requiresUserVerification": false}
```

---

### Task 8: Sweeper + retention use persisted fields

**Goal:** Point the compensating sweep at `last_active_at` and retention at `last_processed_at` + `finalized_at`, removing the per-row `constantize`/`terminal?` derivation (and its deleted-class retention leak).

**Files:**
- Modify: `lib/saga_forge/sweeper_job.rb:39-44` (`sweep_stranded_compensating`)
- Modify: `lib/saga_forge/retention_job.rb:16-34`
- Modify: `lib/saga_forge/state.rb` (add `finalized` / `active` scopes)
- Test: `test/sweeper_test.rb`

**Acceptance Criteria:**
- [ ] Compensating sweep selects rows by `current_state = compensating AND last_active_at <= cutoff`
- [ ] Retention prunes processed events by `last_processed_at <= cutoff` whose state is finalized (or orphaned), with no `constantize`
- [ ] Retention prunes finalized sagas of a since-deleted saga class (the old leak)

**Verify:** `bundle exec ruby -Itest test/sweeper_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests**

In `test/sweeper_test.rb` add:
- a compensating saga whose `last_active_at` is backdated past `sweep_interval` → swept (re-enqueues `CompensationJob`); one whose `last_active_at` is recent → not swept.
- a retention test: a processed event on a finalized state, backdated `last_processed_at`, whose `saga_class` no longer resolves → still pruned.

Match the file's existing time-travel/backdating helpers.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -Itest test/sweeper_test.rb`
Expected: FAIL

- [ ] **Step 3: Add State scopes**

`lib/saga_forge/state.rb`, with the other scopes:

```ruby
    scope :finalized, -> { where.not(finalized_at: nil) }
    scope :active, -> { where(finalized_at: nil) }
```

- [ ] **Step 4: Compensating sweep on `last_active_at`**

`lib/saga_forge/sweeper_job.rb`:

```ruby
    def sweep_stranded_compensating
      State.in_state(State::COMPENSATING).where(last_active_at: ..cutoff).find_each do |state|
        next if state.context.dig("__saga_forge", "comp_error").present?
        CompensationJob.perform_later(state.id)
      end
    end
```

(Backfill note: unreleased, so no legacy `last_active_at`-nil rows exist; `Task 7` stamps it on entry to compensating.)

- [ ] **Step 5: Retention on `last_processed_at` + `finalized_at`**

`lib/saga_forge/retention_job.rb#perform` — join state and filter in SQL; keep the orphan (`state nil`) case:

```ruby
    def perform
      cutoff = SagaForge.config.retention.ago
      scope = Event.processed.where(last_processed_at: ..cutoff)
        .left_joins(:state)
        .where("saga_forge_states.id IS NULL OR saga_forge_states.finalized_at IS NOT NULL")

      scope.in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
    end
```

(Drops the per-row `constantize`/`terminal?`; a finalized state is authoritative regardless of whether its class still loads.)

- [ ] **Step 6: Run to verify it passes**

Run: `bundle exec ruby -Itest test/sweeper_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/saga_forge/sweeper_job.rb lib/saga_forge/retention_job.rb lib/saga_forge/state.rb test/sweeper_test.rb
git commit -m "feat: sweeper/retention key off persisted last_active_at/finalized_at/last_processed_at"
```

```json:metadata
{"files": ["lib/saga_forge/sweeper_job.rb", "lib/saga_forge/retention_job.rb", "lib/saga_forge/state.rb", "test/sweeper_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/sweeper_test.rb", "acceptanceCriteria": ["compensating sweep uses last_active_at", "retention uses last_processed_at+finalized_at, no constantize", "deleted-class leak fixed"], "requiresUserVerification": false}
```

---

### Task 9: Dashboard — finalized vs active

**Goal:** Surface finalized/active using `finalized_at`, and replace the live `terminal?` constantize in the saga actions view with the persisted flag.

**Files:**
- Modify: `saga_forge-dashboard/app/queries/saga_forge/dashboard/sagas_query.rb` (filter)
- Modify: `saga_forge-dashboard/app/queries/saga_forge/dashboard/stats_query.rb` (count)
- Modify: `saga_forge-dashboard/app/views/saga_forge/dashboard/sagas/_actions.html.erb:8`
- Test: dashboard test suite (`saga_forge-dashboard/test/...` if present)

**Acceptance Criteria:**
- [ ] `?filter=finalized` and `?filter=active` return the right rows
- [ ] Stats include a `finalized` count
- [ ] `_actions` uses `@state.finalized_at.nil?` (still-recoverable) instead of `saga_definition.terminal?`

**Verify:** dashboard tests green (or, if none, `_actions` renders without constantizing)

**Steps:**

- [ ] **Step 1: Filter + stats**

`sagas_query.rb#filtered` — add cases:

```ruby
        when "finalized" then base.finalized
        when "active" then base.active
```

`stats_query.rb#counts` — add `finalized: capped(base.finalized)`.

- [ ] **Step 2: Actions view uses the flag**

`_actions.html.erb:8`:

```erb
<% recoverable = @state.finalized_at.nil? && @state.current_state != SagaForge::State::COMPENSATING.to_s %>
```

- [ ] **Step 3: Adapt/add tests**

If the dashboard gem has a query/controller test suite, add assertions for the `finalized`/`active` filters and the `finalized` stat; otherwise add a minimal query test. Run its suite per that gem's Rakefile.

- [ ] **Step 4: Commit**

```bash
git add saga_forge-dashboard/app/queries/ saga_forge-dashboard/app/views/saga_forge/dashboard/sagas/_actions.html.erb
git commit -m "feat(dashboard): finalized/active filters + stat; use persisted finalized_at"
```

```json:metadata
{"files": ["saga_forge-dashboard/app/queries/saga_forge/dashboard/sagas_query.rb", "saga_forge-dashboard/app/queries/saga_forge/dashboard/stats_query.rb", "saga_forge-dashboard/app/views/saga_forge/dashboard/sagas/_actions.html.erb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["finalized/active filters", "finalized stat", "actions uses finalized_at"], "requiresUserVerification": false}
```

---

### Task 10: Docs + full-suite green

**Goal:** Update README, the design spec, and the initializer to the new model; run the whole suite + lint.

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-19-saga-forge-design.md`
- Modify: `lib/generators/saga_forge/templates/initializer.rb` (already touched in Task 1)

**Acceptance Criteria:**
- [ ] No doc references `stay`, `event_id:`, or `digest` as current features
- [ ] Docs describe the forward-only DAG invariant, structural dedup, and the three persisted timestamps
- [ ] `bundle exec rake test` and `bundle exec standardrb` both green

**Verify:** `bundle exec rake` (test + standard) → PASS

**Steps:**

- [ ] **Step 1: README**

Remove the `stay` row from the verbs table and any `stay`-loop prose; remove `event_id:` from the publish/idempotency section and replace with "idempotency is structural — a saga handles each event name once, so `(saga, correlation, event_name)` dedups duplicate deliveries automatically." Add the forward-only invariant ("every processed event advances, branches, or fails — never loops or revisits") and the `finalized_at`/`last_active_at`/`last_processed_at` fields where states/events are documented. Fix the `stall_budget` numbers if not already done in Task 1.

- [ ] **Step 2: Design spec**

In `docs/superpowers/specs/2026-07-19-saga-forge-design.md`: update §A.1 (drop `stay`; note forward-only), §A.2 (structural dedup replaces `event_id`; note the fan-in/orphan-leak fix), §A.3 (the `stall_budget` default; the "clock resets per handled event" line no longer needs the `stay`-loop caveat), §A.4 (compensation dedup now via shared handlers, not `stay` loops), and the decisions table rows for `stay`/`event_id`. Add a short subsection on the persisted timestamps and why they don't violate "current_state never lies" (write-once, atomic with their cause).

- [ ] **Step 3: Full suite + lint**

Run: `bundle exec rake`
Expected: all tests PASS, standard clean. Fix any stragglers (often fixture references or a `stay`/`event_id` mention in a test comment).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-07-19-saga-forge-design.md
git commit -m "docs: forward-only DAG, structural dedup, persisted lifecycle timestamps"
```

```json:metadata
{"files": ["README.md", "docs/superpowers/specs/2026-07-19-saga-forge-design.md"], "verifyCommand": "bundle exec rake", "acceptanceCriteria": ["docs match new model", "full suite + standard green"], "requiresUserVerification": false}
```

---

### Task 11: Commit to Rails-required (remove standalone guards)

**Goal:** Depend on `railties`, load the railtie unconditionally, and delete the three "is Rails present?" guards that only existed to support bare-ActiveRecord/ActiveJob usage. Leave the SolidQueue / RubyVM / jsonb guards untouched — those are adapter/implementation/DB guards, not Rails guards.

**Files:**
- Modify: `saga_forge.gemspec` (add railties dependency)
- Modify: `lib/saga_forge.rb:51-56` (`primary_key_type`), `:83` (railtie require)
- Modify: `lib/saga_forge/router.rb:50-71` (`handler_for` rescue + its comment)

**Acceptance Criteria:**
- [ ] `railties >= 7.1` is a gemspec dependency
- [ ] `require "saga_forge/railtie"` is unconditional
- [ ] No `defined?(Rails)` / `defined?(Rails::Railtie)` / `defined?(Rails.application)` guards remain in `lib/`
- [ ] `defined?(SolidQueue)`, `defined?(RubyVM::InstructionSequence)`, and `respond_to?(:jsonb)` guards remain untouched
- [ ] `bundle exec rake` green (behavior is identical under Rails; the deleted branches were only reachable standalone)

**Verify:** `bundle exec rake test` → PASS, and `grep -rn "defined?(Rails" lib/` → no matches

**Steps:**

- [ ] **Step 1: Add the railties dependency**

`saga_forge.gemspec`, after the `activerecord` dependency:

```ruby
  spec.add_dependency "railties", ">= 7.1"
```

- [ ] **Step 2: Load the railtie unconditionally**

`lib/saga_forge.rb:83`:

```ruby
require "saga_forge/railtie"
```

- [ ] **Step 3: Simplify `primary_key_type`**

`lib/saga_forge.rb:51-56`:

```ruby
    # PK type for engine tables: explicit config → host generator config → Rails default.
    def primary_key_type
      config.primary_key_type ||
        Rails.application&.config&.generators&.options&.dig(:active_record, :primary_key_type) ||
        :primary_key
    end
```

- [ ] **Step 4: Drop the Rails-presence guard in the router**

`lib/saga_forge/router.rb` — trim the `handler_for` comment (remove the "unreachable in practice / defense-in-depth for non-railtie usage (the gem used standalone…)" paragraph, since standalone is no longer supported) and remove the `if defined?(Rails)` wrapper:

```ruby
      # A class whose Definition never compiled (e.g. a mid-declaration DSL
      # error) is simply not a recipient of anything — it's not this publish's
      # problem. Only DSL/boot-time errors are swallowed here; a real recipient
      # whose payload lacks the correlation key raises MissingCorrelationError
      # later, in #resolve, and still aborts the whole publish.
      #
      # Belt-and-braces: the railtie force-compiles every registered class at
      # boot/reload (§A.8), so a broken saga crashes loudly long before any
      # publish reaches here — but if one somehow does, log loudly rather than
      # skip in silence.
      def handler_for(klass, event)
        klass.definition.handler_for(event)
      rescue Error => e
        Rails.logger.error { "[saga_forge] #{klass.name} failed to compile its definition — skipped as recipient: #{e.class}: #{e.message}" }
        nil
      end
```

- [ ] **Step 5: Verify no Rails-presence guards remain, suite green**

Run: `grep -rn "defined?(Rails" lib/`
Expected: no output.

Run: `bundle exec rake test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add saga_forge.gemspec lib/saga_forge.rb lib/saga_forge/router.rb
git commit -m "refactor!: require Rails (railties dep); drop standalone ActiveRecord/ActiveJob guards"
```

```json:metadata
{"files": ["saga_forge.gemspec", "lib/saga_forge.rb", "lib/saga_forge/router.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["railties dependency added", "railtie loaded unconditionally", "no defined?(Rails ...) guards remain", "SolidQueue/RubyVM/jsonb guards untouched"], "requiresUserVerification": false}
```

---

## Self-Review Notes

- **Spec coverage:** stall_budget (T1), schema/dedup key/timestamps (T2), structural publish (T3), tolerant staged inserts / fan-in (T4), remove stay (T5), forward-only DAG (T6), timestamp wiring (T7), sweeper/retention (T8), dashboard finalized (T9), docs (T10), Rails-required guard cleanup (T11). All decisions from the design conversation are covered.
- **Type/name consistency:** `ForwardOnlyError` (T6) is referenced only after it's defined; `guard_forward_only!`/`record_forward_violation` are defined where used; scopes `finalized`/`active` (T8) are used by the dashboard (T9). `last_active_at`/`finalized_at`/`last_processed_at` column names are identical across T2, T7, T8, T9.
- **Ordering/deps:** T2 precedes everything touching the schema (T3, T4, T7). T3 precedes T4 (shared facades). T5 precedes T6 (stay must be gone before the DAG guard's tests). T7 precedes T8/T9 (they read the persisted fields). T1 and T10 bookend.
- **Verification requirement scan:** the original prompt (three architecture questions that evolved into an implementation request) contains no user-verification/human-sign-off requirement → **User Verification: NO**. No `requiresUserVerification: true` task is needed.

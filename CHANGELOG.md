# Changelog

All notable changes to this project are documented in this file.

## [0.1.0] - 2026-08-26

### Bug Fixes

- Json fallback columns get null:false + empty-hash defaults
- Deep-freeze Definition, exact block-extent jump attribution, DSL guards
- Loud boot-time definition compilation, router skip logging, test registry hygiene
- Savepoint duplicate-insert dedup for PG, testable boot compile, doc notes
- Atomic stall counter, not-found discard boundary test
- Lock retry bookkeeping against concurrent deliveries, encoding-safe error capture
- Version-fence compensation commits against concurrent runners
- Index compensating scan, sweep concurrency guards, batched retention deletes
- Status-scoped recovery writes, operator guards, bulk enqueue
- Anchor the migration exists-check to exact names
- Freeze graph members; test + document multi-terminal to_graph
- Close forward-only guard hole in TimeoutJob; stamp last_active_at on timeout/compensation paths

### Documentation

- SagaForge design spec and core implementation plan
- Match recurring.yml snippet comment verbatim to plan wording
- Final task-tracking sync — all 14 plan tasks completed
- Hero example initiates a pending payment; settlement is genuinely async
- Rewrite README to the angarium standard
- Landing page and Pages deploy workflow
- 'events' not 'webhooks' in the hook; drop the headless claim
- Explain the stall budget (timing, tuning, re-delivery)
- Saga_forge-dashboard design spec (phase 2)
- Saga_forge-dashboard implementation plan (phase 2)
- Dashboard plan follow-ups and task completion tracking
- Forward-only DAG + structural dedup implementation plan
- Forward-only DAG, structural dedup, persisted lifecycle timestamps, Rails-required
- Task tracking for DAG/structural-dedup refactor (all tasks complete)
- Mark review-fix task complete

### Features

- Gem scaffold, configuration, combustion test harness
- Schema, ApplicationRecord multi-DB routing, State and Event models
- Port RetryPolicy and CompositeRetryPolicy from chrono_forge
- Saga DSL and compiled Definition with boot validations and mermaid
- Router, external publisher with dedup and guard, saga eager-load railtie
- Execution lifecycle — not-found absorption, halt, stall spin and parking
- Facade verbs, single-commit execution, staged publish delivery, parking re-delivery
- Retry policy integration with per-error budgets and failed-event isolation
- Derived LIFO compensation with per-step commits and tolerant retries
- Version-fenced timeouts with fail! and branch actions
- Sweeper delivery guarantee with stranded-recovery duties, terminal-only retention
- Operator recovery API — retry_stalled!, resume!, compensate!, cancel!
- Install and migrations generators with --database multi-DB support
- Durability suite, CI matrix, README, solid_queue key coverage
- Definition#to_graph, stay_targets, State.compensating (dashboard reads)
- Lower stall_budget default to 3 (parking is cheap and self-healing)
- Structural dedup key + finalized_at/last_active_at/last_processed_at
- Structural (saga,correlation,event) dedup; drop event_id/digest
- Tolerate benign staged-insert collisions via per-row savepoints
- [**breaking**] Remove stay verb; sagas advance, branch, or fail — never loop
- [**breaking**] Enforce forward-only DAG — reject advances into visited states
- Stamp last_active_at/finalized_at/last_processed_at atomically at commit
- Sweeper/retention key off persisted last_active_at/finalized_at/last_processed_at
- [**breaking**] Default job_queue to :default; add maintenance_queue seam

### Miscellaneous Tasks

- Shebang and strict mode for bin/appraise
- LICENSE, lean gem manifest, record A.8 warning deferral
- Add cliff-driven release tooling for both gems
- Exclude the dashboard's demo config.ru from root standard
- Tidy gemspecs for release
- Require MFA to push the gems (rubygems_mfa_required)

### Refactoring

- Boot-validate timeouts, extract shared post-commit effects, timeout concurrency key
- Adopt chrono_forge's migration template pattern (install/upgrade generators)
- [**breaking**] Require Rails (railties dep); drop standalone ActiveRecord/ActiveJob guards

### Testing

- UnknownStateError rollback + duplicate-start race coverage, engine contract comments
- Exercise limits_concurrency through the real solid_queue macro

## [Unreleased]

## [0.1.0] - 2026-08-26

### Bug Fixes

- Test-env CSRF knob, schema staleness note, narrowed asset_digest rescue
- Working relative/absolute time toggle, a11y chrome, format_bytes guard
- Render aria-current as a real attribute, not an escaped string
- Memoize show presenters, deterministic comp order, timeline cap, context preview guard
- Make TimelinePresenter#truncated? side-effect-free
- Danger-style Compensate, clarify bulk button covers the whole class
- Remove em dashes from operator-facing UI copy; realistic seed backtrace
- Close forward-only guard hole in TimeoutJob; stamp last_active_at on timeout/compensation paths

### Documentation

- Comment why the asset route regex stays unanchored + test-env show_exceptions scoping
- Drop stale cf/task residue comment, fix README port example

### Features

- Engine scaffold, config, combustion harness
- Fail-closed auth tests and controller-served digest-busted assets
- Layout chrome, view helpers, tailwind styles, poll refresh
- Sagas index with keyset query and capped stats
- Saga show with merged timeline and context tree
- Overview, stalled, and suspended pages
- State-machine graph with per-instance overlay
- Operator actions and bulk recovery
- Preview server, README, packaging
- Finalized/active filters + stat; drop stay fixture; use persisted finalized_at

### Miscellaneous Tasks

- Add cliff-driven release tooling for both gems
- Tidy gemspecs for release
- Require MFA to push the gems (rubygems_mfa_required)

### Refactoring

- Reuse core State scopes in queries; cover keyset Newer path
- Reword sibling-gem comments to saga terms; reuse ledger_order scope

### Testing

- Cover graph overlay per-node isolation, stale events, namespaced classes

## [Unreleased]

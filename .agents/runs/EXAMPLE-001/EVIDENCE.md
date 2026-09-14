# Evidence: EXAMPLE-001

## Repository

Commit: `unborn repository; no commit ID exists`

Relevant files:

- `src/task_registry.go`
- `tests/task_registry_test.go`
- `docs/architecture.md`

## Wiki

### Entities

- [[task-registry]]

### Decisions

- [[use-in-memory-storage-for-example]]

### Lessons

- [[validate-input-before-state-change]]

### Concepts

- [[engineering-determinism]]
- [[two-transaction-model]]

### Sources

- [[architecture-overview]]
- [[2026-09-14-bootstrap]]

## Derived constraints

- Do not introduce a database or dependencies.
- Validate before mutating registry state.
- Keep wiki read-only throughout the code transaction.
- Use the smallest in-memory implementation and Go standard library.

## Freeze

Evidence version: v1  
Frozen at: PLAN FREEZE for EXAMPLE-001.


# Evidence: EXAMPLE-001

## Repository

Baseline SHA: `PENDING-V2-BASELINE`

Inspected paths:

- `src/task_registry.go`
- `tests/task_registry_test.go`
- `docs/architecture.md`
- `.agents/WORKFLOW.md`
- `.agents/modes/deterministic.yaml`

## Wiki references

- Entity: [[task-registry]]
- Decision: [[use-in-memory-storage-for-example]]
- Lesson: [[validate-input-before-state-change]]
- Concepts: [[engineering-determinism]], [[two-transaction-model]]
- Source: [[architecture-overview]]

## Derived constraints

- Preserve in-memory storage and error conventions.
- Return a value, not an internal slice/pointer.
- Add only focused lookup tests.
- Wiki remains read-only until CODE DONE.

## Freeze metadata

Version: v1  
Frozen only after actual baseline SHA replaces the pending marker and `agent-run.sh freeze EXAMPLE-001` records hashes.


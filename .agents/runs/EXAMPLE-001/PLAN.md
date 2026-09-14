# Plan: EXAMPLE-001

## Behavior

Create a dependency-free in-memory registry that trims titles, rejects blanks before mutation, lists copies of state, and marks an existing task complete. Add tests and the control/knowledge scaffolding that demonstrates the deterministic workflow.

## Files to modify

- None; this is an initial repository.

## Files to create

See **Expected changed files** below.

## Files to delete

- None.

## Tests

- Creation, listing, and completion lifecycle.
- Blank title rejection without state change.
- Missing-task completion error.

## Verification commands

```bash
./scripts/verify.sh
./scripts/wiki-lint.sh
./scripts/check-scope.sh .agents/runs/EXAMPLE-001/PLAN.md
```

## Expected changed files

- .agents/ENGINEERING.md
- .agents/EVIDENCE_TEMPLATE.md
- .agents/GIT.md
- .agents/KNOWLEDGE.md
- .agents/RESULT_TEMPLATE.md
- .agents/TASK_TEMPLATE.md
- .agents/VERIFICATION.md
- .agents/VIBECOSYSTEM.md
- .agents/WORKFLOW.md
- .agents/modes/deterministic.md
- .agents/modes/explore.md
- .agents/modes/review.md
- .agents/runs/EXAMPLE-001/EVIDENCE.md
- .agents/runs/EXAMPLE-001/PLAN.md
- .agents/runs/EXAMPLE-001/RESULT.md
- .agents/runs/EXAMPLE-001/RUN.yaml
- .agents/runs/EXAMPLE-001/TASK.md
- .gitignore
- AGENTS.md
- CLAUDE.md
- README.md
- docs/architecture.md
- docs/wiki/CLAUDE.md
- docs/wiki/KNOWLEDGE-PIPELINE.md
- docs/wiki/archive/README.md
- docs/wiki/concepts/engineering-determinism.md
- docs/wiki/concepts/two-transaction-model.md
- docs/wiki/decisions/use-in-memory-storage-for-example.md
- docs/wiki/entities/task-registry.md
- docs/wiki/index.md
- docs/wiki/lessons/validate-input-before-state-change.md
- docs/wiki/lint-report.md
- docs/wiki/log.md
- docs/wiki/raw/sessions/2026-09-14-bootstrap.md
- docs/wiki/sources/architecture/architecture-overview.md
- docs/wiki/sources/session/2026-09-14-bootstrap.md
- docs/wiki/syntheses/README.md
- go.mod
- scripts/check-scope.sh
- scripts/verify.sh
- scripts/wiki-lint.sh
- src/task_registry.go
- tests/task_registry_test.go

## Freeze

Plan version: v1  
Frozen at: IMPLEMENT for EXAMPLE-001.


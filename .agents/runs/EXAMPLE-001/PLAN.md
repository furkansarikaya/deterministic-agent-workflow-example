---
scope:
  - path: src/task_registry.go
    criteria: [AC-1, AC-2]
  - path: tests/task_registry_test.go
    criteria: [AC-1, AC-2, AC-3]
  - path: .agents/runs/EXAMPLE-001/EVIDENCE.md
    criteria: [AC-3]
  - path: .agents/runs/EXAMPLE-001/RUN.yaml
    criteria: [AC-3]
  - path: .agents/runs/EXAMPLE-001/RESULT.md
    criteria: [AC-3, AC-4]
  - path: .agents/runs/EXAMPLE-001/review/code-review.md
    criteria: [AC-3]
  - path: .agents/runs/EXAMPLE-001/review/verification.md
    criteria: [AC-3]
  - path: docs/wiki/raw/sessions/2026-09-14-example-001.md
    criteria: [AC-4]
  - path: docs/wiki/sources/session/2026-09-14-example-001.md
    criteria: [AC-4]
  - path: docs/wiki/log.md
    criteria: [AC-4]
  - path: docs/wiki/lint-report.md
    criteria: [AC-4]
---

# Plan: EXAMPLE-001

## Behavior

Add a focused `Find(id int) (Task, error)` registry method. It scans existing tasks, returns the value on match, and reuses `ErrTaskNotFound` otherwise.

## Tests

Add success and missing-ID coverage. Existing lifecycle and input-validation tests remain unchanged.

## Verification commands

```sh
./scripts/verify.sh
./scripts/agent.sh verify-freeze EXAMPLE-001
./scripts/agent.sh verify-scope EXAMPLE-001
./scripts/wiki-lint.sh
```

## Amendment rule

After freeze, additional paths or facts require an amendment and explicit re-freeze.

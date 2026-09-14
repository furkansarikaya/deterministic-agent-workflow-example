---
scope:
  - path: AGENTS.md
    criteria: [AC-1]
  - path: CLAUDE.md
    criteria: [AC-1]
  - path: README.md
    criteria: [AC-1, AC-2, AC-4, AC-5, AC-6]
  - path: docs/architecture.md
    criteria: [AC-1, AC-2, AC-4, AC-5]
  - path: .agents/config.yaml
    criteria: [AC-1, AC-2, AC-4]
  - path: .agents/ACTIVE_RUN
    criteria: [AC-1]
  - path: .agents/WORKFLOW.md
    criteria: [AC-1, AC-2, AC-5]
  - path: .agents/ENGINEERING.md
    criteria: [AC-3]
  - path: .agents/GIT.md
    criteria: [AC-3]
  - path: .agents/KNOWLEDGE.md
    criteria: [AC-5, AC-6]
  - path: .agents/VERIFICATION.md
    criteria: [AC-2, AC-3, AC-6]
  - path: .agents/VIBECOSYSTEM.md
    criteria: [AC-4]
  - path: .agents/ENFORCEMENT.md
    criteria: [AC-2, AC-4]
  - path: .agents/TASK_TEMPLATE.md
    criteria: [AC-2]
  - path: .agents/EVIDENCE_TEMPLATE.md
    criteria: [AC-2]
  - path: .agents/PLAN_TEMPLATE.md
    criteria: [AC-2, AC-3]
  - path: .agents/PLAN_TEMPLATE.md
    criteria: [AC-2, AC-3]
  - path: .agents/RESULT_TEMPLATE.md
    criteria: [AC-2]
  - path: .agents/AMENDMENT_TEMPLATE.md
    criteria: [AC-2]
  - path: .agents/modes/deterministic.yaml
    criteria: [AC-1, AC-2, AC-4]
  - path: .agents/modes/explore.yaml
    criteria: [AC-1]
  - path: .agents/modes/review.yaml
    criteria: [AC-1]
  - path: .agents/modes/deterministic.md
    criteria: [AC-1, AC-2]
  - path: .agents/modes/explore.md
    criteria: [AC-1]
  - path: .agents/modes/review.md
    criteria: [AC-1]
  - path: .agents/runs/BOOTSTRAP-000/RESULT.md
    criteria: [AC-5]
  - path: .agents/runs/EXAMPLE-001/TASK.md
    criteria: [AC-5]
  - path: .agents/runs/EXAMPLE-001/EVIDENCE.md
    criteria: [AC-5]
  - path: .agents/runs/EXAMPLE-001/PLAN.md
    criteria: [AC-3, AC-5]
  - path: .agents/runs/EXAMPLE-001/RUN.yaml
    criteria: [AC-2, AC-4, AC-5]
  - path: .agents/runs/EXAMPLE-001/RESULT.md
    criteria: [AC-5]
  - path: .agents/runs/EXAMPLE-001/review/code-review.md
    criteria: [AC-5]
  - path: .agents/runs/EXAMPLE-001/review/verification.md
    criteria: [AC-5]
  - path: .agents/runs/V2-UPGRADE/GAP_ANALYSIS.md
    criteria: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6]
  - path: .agents/runs/V2-UPGRADE/TASK.md
    criteria: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6]
  - path: .agents/runs/V2-UPGRADE/EVIDENCE.md
    criteria: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6]
  - path: .agents/runs/V2-UPGRADE/PLAN.md
    criteria: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6]
  - path: scripts/agent-policy.sh
    criteria: [AC-1, AC-2]
  - path: scripts/agent-run.sh
    criteria: [AC-1, AC-2, AC-3, AC-5]
  - path: scripts/check-scope.sh
    criteria: [AC-3]
  - path: scripts/wiki-lint.sh
    criteria: [AC-6]
  - path: scripts/control-plane-test.sh
    criteria: [AC-2, AC-3, AC-6]
  - path: docs/wiki/CLAUDE.md
    criteria: [AC-5, AC-6]
  - path: docs/wiki/KNOWLEDGE-PIPELINE.md
    criteria: [AC-5]
  - path: docs/wiki/log.md
    criteria: [AC-5, AC-6]
  - path: docs/wiki/lint-report.md
    criteria: [AC-6]
  - path: docs/wiki/decisions/use-in-memory-storage-for-example.md
    criteria: [AC-5]
  - path: docs/wiki/sources/architecture/architecture-overview.md
    criteria: [AC-5]
  - path: docs/wiki/sources/session/2026-09-14-bootstrap.md
    criteria: [AC-5]
  - path: docs/wiki/raw/sessions/2026-09-14-bootstrap.md
    criteria: [AC-5]
  - path: src/task_registry.go
    criteria: [AC-5, AC-6]
  - path: tests/task_registry_test.go
    criteria: [AC-5, AC-6]
---

# Plan: V2-UPGRADE

## Behavior

Install a small YAML/Markdown/shell control plane. It establishes the V2 baseline and then records EXAMPLE-001 as the bounded feature demonstration. The Go feature adds a task lookup method and its tests.

## Amendments

Frozen EXAMPLE-001 artifacts are immutable. New information requires an amendment under `amendments/`, new evidence/plan version, and an explicit re-freeze. The V2 upgrade itself is the transition that creates this machinery.

## Tests and verification

Run the commands in TASK.md. Control-plane tests use temporary repositories and never change the real worktree.

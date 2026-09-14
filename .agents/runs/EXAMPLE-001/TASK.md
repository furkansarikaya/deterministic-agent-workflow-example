# Task: EXAMPLE-001

## Objective

Add read-only lookup of one task by ID to the existing in-memory task registry.

## Context

This is a genuine deterministic task against a real control-plane baseline. It must use the real baseline SHA recorded in evidence before freeze.

## Allowed scope

Only the frozen paths in PLAN.md: registry implementation/test, run evidence/fingerprint/review/result artifacts, and post-CODE-DONE factual wiki records.

## Forbidden scope

No dependencies, persistence, API, refactor, database, wiki write during Transaction A, swarm, memory, or automatic learning.

## Required behavior

Return an existing task by ID without exposing mutable state; return `ErrTaskNotFound` for a missing ID.

## Acceptance criteria

- AC-1: `Find(id)` returns the matching task without changing registry state.
- AC-2: `Find(id)` returns `ErrTaskNotFound` when absent.
- AC-3: Focused regression tests, Go verification, freeze, scope, review, and independent verifier pass.
- AC-4: Factual post-CODE-DONE knowledge records are linked and lint-clean.

## Verification commands

```sh
./scripts/verify.sh
./scripts/agent.sh verify-freeze EXAMPLE-001
./scripts/agent.sh verify-scope EXAMPLE-001
./scripts/wiki-lint.sh
```

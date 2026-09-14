# Task: EXAMPLE-001

## Objective

Bootstrap the workflow example and add the sample registry capability to mark an existing task complete.

## Context

This is the initial repository state. The application exists only to exercise the control architecture.

## Allowed scope

Create the listed bootstrap control-plane, wiki, Go registry, tests, and scripts files.

## Forbidden scope

No dependencies, database, HTTP framework, network service, uncontrolled swarm, or wiki writes during the code transaction.

## Required behavior

Create/list/complete in-memory tasks; reject blank titles before state changes; report a missing task.

## Constraints

Use profile `core`, mode `deterministic`, and allowlisted skills `coding-standards` and `tdd-workflow`. One implementation worker only.

## Existing pattern references

[[task-registry]], [[use-in-memory-storage-for-example]], and [[validate-input-before-state-change]].

## Acceptance criteria

1. The required control-plane and wiki structure exists.
2. The Go registry creates, lists, completes, and validates tasks.
3. Automated tests cover success and error paths.
4. Verification, wiki lint, and scope checks succeed.
5. The run has frozen evidence, plan, fingerprint, and result artifacts.

## Verification commands

```bash
./scripts/verify.sh
./scripts/wiki-lint.sh
./scripts/check-scope.sh .agents/runs/EXAMPLE-001/PLAN.md
```

## Completion response

Report created structure, application behavior, workflow, wiki transactions, exact verification, and genuine caveats.


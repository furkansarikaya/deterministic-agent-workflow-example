# Verification: EXAMPLE-001

## Phase identity

Role: `verifier` checklist phase
Worker/run identity: unavailable to this repository; no identity is fabricated.
Independent phase: performed after the recorded code-review verdict.

## Exact checks

- `./scripts/verify.sh` — PASS: `go build ./...`, `go test ./...`, and `go vet ./...`.
- `./scripts/control-plane-test.sh` — PASS: valid freeze and authorized scope pass; tampered evidence, unexpected path, missing active task, and broken wiki link fail as expected.
- `./scripts/agent-policy.sh effective` — PASS: deterministic/core policy resolved with memory/recall/swarm denied by policy, one implementation worker, review/verifier required, and two bounded fixes.
- `./scripts/agent-run.sh verify-freeze EXAMPLE-001` — PASS.
- `./scripts/check-scope.sh EXAMPLE-001` — PASS.
- `./scripts/wiki-lint.sh` — PASS: 0 errors, 0 warnings.

## Verdict

PASS. Bounded fixes used: 0. CODE DONE is permitted; Transaction B may begin.

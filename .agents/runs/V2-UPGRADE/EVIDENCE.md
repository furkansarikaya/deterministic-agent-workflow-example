# Evidence: V2-UPGRADE

## Repository

Baseline commit: `7c9eabd`

Inspected paths:

- `AGENTS.md`, `CLAUDE.md`, `README.md`, `.agents/**`
- `docs/architecture.md`, `docs/wiki/**`, `scripts/**`
- `src/task_registry.go`, `tests/task_registry_test.go`

## Capability source

Local vibecosystem v3.4.0 at `/Users/furkansarikaya/claude/vibecosystem`:

- `profiles/runtime-manifest.json`: core/quality/context/memory/orchestration/full profiles.
- `.codex/agents/luna-worker.toml`: Codex bounded worker contract.
- `agents/code-reviewer.md` and `agents/verifier.md`: review/verifier roles.
- `hooks/hooks.json`: hook names and broad behavior.

## Derived constraints

- Use actual names only: core, `luna_worker`, `code-reviewer`, `verifier`, and installed core skills.
- Memory and orchestration are profile-dependent; the repository can constrain them by policy but cannot deactivate globally installed hooks itself.
- No V1 historical SHA can be invented. `7c9eabd` is the truthful bootstrap commit.
- Keep the Go sample dependency-free.

## Freeze

This V2 upgrade is an explicit user-directed migration. Its task/evidence/plan are planning artifacts; V2’s new freeze tooling will govern EXAMPLE-001 after the V2 baseline is established.


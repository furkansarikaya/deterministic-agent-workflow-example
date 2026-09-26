# Vibecosystem adapter contract

Inspected local vibecosystem v3.4.0 at `/Users/furkansarikaya/claude/vibecosystem`. Its `core` profile contains actual `code-reviewer` and `verifier` roles plus `coding-standards`, `tdd-workflow`, `review`, `security-review`, and `verification-loop`. The Codex adapter supplies `luna_worker` with fixed model authority.

Profile means capabilities; mode means permitted behavior. This example allows the listed skills, `luna_worker` as the single implementation worker, and vibecosystem reviewers/verifiers as the bounded Reviewer/Verifier (and comparable read-only agents as Explorer, Architect and QA) — each only under an explicit assignment from the orchestrator. It denies memory, `session-start-recall`, `smart-memory-recall`, `agent-tuner`, `self-learner` writes, `maestro`, `kraken`, and automatic swarm/context injection.

Host hooks are globally controlled, so these denials are policy-only here. Actual core `credential-deny` is platform-enforced only if installed/active. Claude-only model metadata is never reused for Codex.

An explicit `implementation_worker` invocation allows implementation capability only. Recursive orchestration, swarm, and delegation remain denied by role policy in that invocation; standalone Claude and Codex retain the default `full_lifecycle` role.

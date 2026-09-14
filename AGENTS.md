# Deterministic agent control plane

## Codex boot protocol

1. Read this file, then `.agents/config.yaml` and `.agents/WORKFLOW.md`.
2. Resolve policy with `./scripts/agent-policy.sh effective`.
3. Resolve exactly one active task with `./scripts/agent-run.sh status`.
4. Read its `TASK.md`; enter read-only DISCOVER.
5. Read task-relevant wiki pages in `.agents/KNOWLEDGE.md` order.
6. Freeze evidence and plan, then run `./scripts/agent-run.sh verify-freeze <TASK-ID>`.
7. IMPLEMENT is permitted only when task, evidence, plan, policy hashes, and scope mappings validate.

Default mode/profile are `deterministic/core`. `.agents/ACTIVE_RUN` is the only selector. If it is blank, malformed, missing, or ambiguous, do not implement. For a direct new-change request, create a new task run and make it active before edits; clarify only material conflicts, unrecoverable missing facts, irreversible actions, or material scope expansion.

Before edits read TASK, EVIDENCE, PLAN, effective policy, and relevant engineering/verification rules. User-owned uncommitted changes are never reset, overwritten, staged, or claimed. Deterministic wiki use is bounded read-only until CODE DONE. Vibecosystem is capability-only: use allowlisted capabilities inside the frozen contract; never auto-start swarm, recall, learning, or scope mutation.

DONE is blocked by failed acceptance criteria, freeze mismatch, unexpected/unmapped paths, failed verification, absent review/verifier artifacts, or unexplained user changes. Stop when all gates pass.


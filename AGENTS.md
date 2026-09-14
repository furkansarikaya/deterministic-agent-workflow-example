# Deterministic agent control plane

## Codex boot protocol

1. Read this file, then `.agents/config.yaml` and `.agents/WORKFLOW.md`.
2. Resolve policy with `./scripts/agent.sh effective`.
3. Resolve the active task with `./scripts/agent.sh status`.
4. If active, read its `TASK.md`, then record `./scripts/agent.sh baseline <TASK-ID>`.
5. Enter read-only DISCOVER and read task-relevant wiki pages in `.agents/KNOWLEDGE.md` order.
6. Build evidence and plan, freeze them, then run `./scripts/agent.sh verify-freeze <TASK-ID>`.
7. IMPLEMENT is permitted only when task, evidence, plan, policy hashes, and application scope mappings validate.

Default mode/profile are `deterministic/core`. `.agents/ACTIVE_RUN` is the only selector. The checked-in template intentionally leaves it blank: `status` reports no active task and implementation is blocked. A malformed, missing, or ambiguous selector is an error. For a direct new-change request, create a new task run, make it active, and record `./scripts/agent.sh baseline <TASK-ID>` before DISCOVER; clarify only material conflicts, unrecoverable missing facts, irreversible actions, or material scope expansion.

Use progressive disclosure: TASK and current repository/tests are primary context. Load ENGINEERING, GIT, VERIFICATION, KNOWLEDGE, VIBECOSYSTEM, or other control documents only when their rules apply to the current operation; never bulk-load `.agents/**`, `docs/wiki/**`, unrelated runs, or session history. Query the wiki only if TASK/repository/tests leave a relevant fact unresolved, beginning at its index. Evidence and plans contain references and decisions, not copied documents. User-owned uncommitted changes are never reset, overwritten, staged, or claimed; the baseline fingerprints pre-existing work so scope checks can distinguish it from later task changes. Deterministic wiki use is bounded read-only until CODE DONE. Vibecosystem is capability-only: use allowlisted capabilities inside the frozen contract; never auto-start swarm, recall, learning, or scope mutation.

DONE is blocked by failed acceptance criteria, freeze mismatch, unexpected/unmapped paths, failed verification, absent review/verifier artifacts, or unexplained user changes. Stop when all gates pass.

This example’s control-plane/template maintenance is an explicit exception only when the user requests it: maintain current files directly without creating a demonstration run. Normal application work always uses this protocol.

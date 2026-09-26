# Deterministic agent control plane

The canonical workflow is `.agents/WORKFLOW.md`: a deterministic orchestrator, bounded specialist roles, explicit artifacts, independent quality gates. This file is the boot protocol; do not restate the workflow elsewhere.

## Boot protocol (any agent: Claude Code, Codex, ...)

1. Read this file, then `.agents/config.yaml` and `.agents/WORKFLOW.md`.
2. Resolve policy with `./scripts/agent.sh effective`, then the active task with `./scripts/agent.sh status`. `.agents/ACTIVE_RUN` is the only selector; the checked-in template leaves it blank, so `status` reports no active task and implementation is blocked. A malformed, missing or ambiguous selector is an error.
3. For a direct new-change request: create `.agents/runs/<TASK-ID>/` from `.agents/templates/`, make it active, then `classify` (see "Pipeline selection" in the workflow), `branch`, `baseline`. Clarify only material conflicts, unrecoverable missing facts, irreversible actions or material scope expansion.
4. Enter read-only DISCOVER; consult `.agents/KNOWLEDGE.md` and task-relevant wiki pages only if TASK, repository and tests leave a fact unresolved.
5. Produce and freeze what the pipeline requires (`./scripts/agent.sh pipeline <TASK-ID>`), then run `./scripts/agent.sh freshness <TASK-ID>`.
6. IMPLEMENT is permitted only when task, evidence, plan, QA plan, policy hashes, source/base freshness and scope mappings validate.
7. Independent gates, `CODE_DONE`, report, `DONE`, `cleanup`, then stop.

## Roles and topology

`AGENT_ROLE` is invocation-scoped, never agent identity: the default `full_lifecycle` is the Orchestrator and lets either Claude or Codex own the whole lifecycle. A session explicitly delegated a bounded role (`implementation_worker`, `explorer`, `architect`, `independent_qa`, `independent_reviewer`, `independent_verifier`) obeys that role's boundary in `.agents/WORKFLOW.md`, returns its result to the orchestrator, and cannot plan, freeze, advance the task, deliver, or delegate. Only the Orchestrator declares DONE. There is no swarm and no recursive delegation; implementation has exactly one worker.

Execution topology (`./scripts/agent.sh resolve_topology`) is separate from role: under `standalone`, `full_lifecycle` implements RED/GREEN itself; under `orchestrated` it must delegate implementation to `implementation_worker` through `scripts/worker-run.sh` and must not implement application code — and a failed worker invocation leaves the task incomplete rather than licensing self-implementation.

## Rules that always apply

- Progressive disclosure: TASK and the current repository/tests are primary context. Load `.agents/ENGINEERING.md`, `GIT.md`, `VERIFICATION.md`, `KNOWLEDGE.md`, `VIBECOSYSTEM.md` only when their rules apply; never bulk-load `.agents/**`, `docs/wiki/**`, or session history. Evidence and plans hold references and decisions, not copied documents.
- User-owned uncommitted changes are never reset, overwritten, staged or claimed; the baseline fingerprints them so scope checks can tell them from task changes.
- Vibecosystem is capability-only: use allowlisted capabilities inside the frozen contract; never auto-start swarm, recall, learning or scope mutation.
- `CODE_DONE` is blocked by failed or missing required gates, freeze/freshness mismatch, unexpected or unmapped paths, stale fingerprints, missing implementation evidence or TDD exemption, or unexplained user changes. It never authorizes commit, push, PR/MR or external task updates; those need explicit authorization after `delivery-check`. `DONE` additionally needs the knowledge step, a published and verified completion report, and is followed by `cleanup`.

This example's control-plane and template maintenance is an explicit exception, only when the user requests it: maintain the current files directly, without creating a run. Normal application work always uses this protocol.

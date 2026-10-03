# Deterministic agent control plane

The canonical workflow is `.agents/WORKFLOW.md`: a deterministic orchestrator, bounded specialist roles, explicit artifacts, independent quality gates. This file is the boot protocol. Do not restate the workflow elsewhere.

## Boot protocol (any agent: Claude Code, Codex, ...)

1. Read this file, then `.agents/config.yaml` and `.agents/WORKFLOW.md`.
2. Resolve policy with `./scripts/agent.sh effective`, then the active task with `./scripts/agent.sh status`. `.agents/ACTIVE_RUN` is the only selector; the checked-in template leaves it blank, so `status` reports no active task and implementation is blocked. A malformed, missing or ambiguous selector is an error.
3. For a direct new-change request: create `.agents/runs/<TASK-ID>/` from `.agents/templates/`, make it active, then `classify` (see "Pipeline selection" in the workflow), `branch`, `baseline`. Clarify only material conflicts, unrecoverable missing facts, irreversible actions or material scope expansion.
4. Enter read-only DISCOVER; consult `.agents/KNOWLEDGE.md` and task-relevant wiki pages only if TASK, repository and tests leave a fact unresolved.
5. Produce and freeze what the pipeline requires (`./scripts/agent.sh pipeline <TASK-ID>`), then run `./scripts/agent.sh freshness <TASK-ID>`.
6. IMPLEMENT is permitted only when task, evidence, plan, QA plan, policy hashes, source/base freshness and scope mappings validate.
7. Independent gates, `CODE_DONE`, report, `DONE`, `cleanup`, then stop.

## Roles and topology

`AGENT_ROLE` names the invocation, never the agent. The default `full_lifecycle` is the Orchestrator: Claude or Codex MAY own the whole lifecycle. A session delegated a bounded role MUST obey that role's boundary in `.agents/WORKFLOW.md` ("Modes and roles") and MUST return its result to the Orchestrator. A bounded role MUST NOT plan, freeze, advance the task, deliver or delegate. Only the Orchestrator declares DONE. Topology (`standalone` or `orchestrated`) is separate from role: see "Execution topology" in the workflow.

## Rules that always apply

- Progressive disclosure: TASK and the current repository and tests are the primary context. Load `.agents/ENGINEERING.md`, `GIT.md`, `VERIFICATION.md`, `KNOWLEDGE.md`, `OVERSIGHT.md`, `VIBECOSYSTEM.md` only when their rules apply. MUST NOT bulk-load `.agents/**`, `docs/wiki/**` or session history. Evidence and plans hold references and decisions, not copied documents.
- MUST NOT reset, overwrite, stage or claim user-owned uncommitted changes. The baseline fingerprints them so scope checks can tell them from task changes.
- Vibecosystem is capability-only. Use allowlisted capabilities inside the frozen contract. MUST NOT auto-start swarm, recall, learning or scope mutation.
- `CODE_DONE` FAILS on: a failed or missing required gate, a freeze or freshness mismatch, an unexpected or unmapped path, a stale fingerprint, missing implementation evidence or TDD exemption, or an unexplained user change. `CODE_DONE` grants no delivery right (WORKFLOW "Completion, delivery and cleanup").
- Oversight output (`summary`, `report`) is a projection of run state, not evidence. It MUST NOT change a run artifact (`.agents/OVERSIGHT.md`). Load `.agents/skills/oversight-report/SKILL.md` only when the user asks for a report.

This example's control-plane and template maintenance is an explicit exception, only when the user requests it: maintain the current files directly, without creating a run. Normal application work always uses this protocol.

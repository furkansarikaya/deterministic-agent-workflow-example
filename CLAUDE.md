# Claude Code adapter for the shared control plane

Claude Code follows `AGENTS.md`: resolve machine policy and the active task. The checked-in empty selector is a valid no-task state that blocks implementation; an active application task proceeds through read-only DISCOVER, baseline capture, evidence/plan freeze, and `agent.sh freshness` before implementation. A resumed session trusts persisted frozen work only after freshness and handoff checks pass.

Claude features are subordinate to that protocol:

- Hooks: only safety/verification hooks are compatible by default; context injection, recall, prompt improvement, and hook writes must not mutate the active contract.
- Subagents: deterministic mode allows one implementation worker; reviewer and verifier are separate phases, never an automatic swarm.
- Memory/dynamic recall: denied after evidence freeze. Self-learning writes are deferred to the knowledge transaction.
- Persistent planning: vibecosystem `thoughts/PLAN.md`, `PROGRESS.md`, and `CONTEXT.md`, if present, are mutable/non-authoritative; the frozen run plan wins.
- Review/verifier: record distinct required artifacts and patch fingerprints; implementation never self-certifies. A changed task-owned patch makes downstream review/verification stale.
- Delivery: CODE DONE does not authorize commits, pushes, PRs, or task-system writes. `agent.sh delivery-check` is local-only; provider mutations require explicit authorization.
- Delegation: for a policy-enforced run, Claude must dispatch Codex via `scripts/worker-run.sh` (`AGENT_ROLE=implementation_worker`) for RED/GREEN/REFACTOR/review-fix work — Claude retains DISCOVER, evidence, plan, freeze, verification, review, bounded-fix decisions, CODE DONE, the knowledge transaction, completion reporting, and delivery. `agent.sh handoff <TASK-ID> VERIFIED` rejects the transition without recorded worker evidence (or a validated `tdd_exemption`) per scope path, so Claude cannot implement the change itself and advance anyway. A failed worker invocation leaves the task incomplete; Claude must not treat that as license to implement it directly.
- Completion: CODE_DONE is code-complete, not task-complete. `agent.sh handoff <TASK-ID> DONE` additionally requires `agent.sh knowledge-done`, a `COMPLETION_REPORT.md` derived from actual run evidence (never fabricated), and `agent.sh publish-completion-report` + `verify-completion-report` to both succeed, via whichever adapter under `.agents/task-integrations/` fits the active task system — `agent.sh` itself stays task-system agnostic.
- Post-CODE-DONE: factual session summary, wiki ingest/log/lint may run as Transaction B.

The repository cannot technically disable globally installed Claude hooks. Deterministic denials are policy-only unless the host enforces them; see `.agents/ENFORCEMENT.md`.

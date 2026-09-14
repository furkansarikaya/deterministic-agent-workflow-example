# Claude Code adapter for the shared control plane

Claude Code follows `AGENTS.md`: resolve machine policy and the active task. The checked-in empty selector is a valid no-task state that blocks implementation; an active application task proceeds through read-only DISCOVER, baseline capture, evidence/plan freeze, and `agent.sh freshness` before implementation. A resumed session trusts persisted frozen work only after freshness and handoff checks pass.

Claude features are subordinate to that protocol:

- Hooks: only safety/verification hooks are compatible by default; context injection, recall, prompt improvement, and hook writes must not mutate the active contract.
- Subagents: deterministic mode allows one implementation worker; reviewer and verifier are separate phases, never an automatic swarm.
- Memory/dynamic recall: denied after evidence freeze. Self-learning writes are deferred to the knowledge transaction.
- Persistent planning: vibecosystem `thoughts/PLAN.md`, `PROGRESS.md`, and `CONTEXT.md`, if present, are mutable/non-authoritative; the frozen run plan wins.
- Review/verifier: record distinct required artifacts and patch fingerprints; implementation never self-certifies. A changed task-owned patch makes downstream review/verification stale.
- Delivery: CODE DONE does not authorize commits, pushes, PRs, or task-system writes. `agent.sh delivery-check` is local-only; provider mutations require explicit authorization.
- Delegation: Claude may explicitly dispatch Codex with `AGENT_ROLE=implementation_worker`. Claude retains DISCOVER, evidence, plan, freeze, verification, review, bounded-fix decisions, and CODE DONE; Codex returns after implementation.
- Post-CODE-DONE: factual session summary, wiki ingest/log/lint may run as Transaction B.

The repository cannot technically disable globally installed Claude hooks. Deterministic denials are policy-only unless the host enforces them; see `.agents/ENFORCEMENT.md`.

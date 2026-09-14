# Claude Code adapter for the shared control plane

Claude Code follows `AGENTS.md`: resolve machine policy and the one active task, DISCOVER read-only, freeze evidence/plan, then implement only after `agent.sh verify-freeze` passes.

Claude features are subordinate to that protocol:

- Hooks: only safety/verification hooks are compatible by default; context injection, recall, prompt improvement, and hook writes must not mutate the active contract.
- Subagents: deterministic mode allows one implementation worker; reviewer and verifier are separate phases, never an automatic swarm.
- Memory/dynamic recall: denied after evidence freeze. Self-learning writes are deferred to the knowledge transaction.
- Persistent planning: vibecosystem `thoughts/PLAN.md`, `PROGRESS.md`, and `CONTEXT.md`, if present, are mutable/non-authoritative; the frozen run plan wins.
- Review/verifier: record distinct required artifacts; implementation never self-certifies.
- Post-CODE-DONE: factual session summary, wiki ingest/log/lint may run as Transaction B.

The repository cannot technically disable globally installed Claude hooks. Deterministic denials are policy-only unless the host enforces them; see `.agents/ENFORCEMENT.md`.

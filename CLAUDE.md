# Claude Code adapter for the shared control plane

Claude Code follows `AGENTS.md` and `.agents/WORKFLOW.md`: resolve machine policy and the active task; the checked-in empty selector is a valid no-task state that blocks implementation. A resumed session trusts persisted frozen work only after freshness and handoff checks pass.

Claude features are subordinate to that protocol:

- Hooks: only safety/verification hooks are compatible by default; context injection, recall, prompt improvement and hook writes must not mutate the active contract. The repository cannot technically disable globally installed hooks; see `.agents/ENFORCEMENT.md`.
- Subagents: Claude subagents are how bounded roles are run (an Explorer, the Architect, QA, Reviewer, Verifier, or the single implementation worker), each with an explicit assignment and no ability to delegate further. No automatic swarm; at most one implementation worker; exploration parallelism is bounded by the run's classification.
- Memory/dynamic recall: denied after evidence freeze. Self-learning writes are deferred to the optional knowledge transaction.
- Persistent planning: vibecosystem `thoughts/PLAN.md`, `PROGRESS.md` and `CONTEXT.md`, if present, are mutable and non-authoritative; the frozen run plan wins.
- Execution topology decides how Claude implements: under `standalone`, Claude (as `full_lifecycle`) implements RED/GREEN itself and records that evidence under its own role; under `orchestrated`, Claude dispatches Codex via `scripts/worker-run.sh` and never implements application code itself, and a failed worker invocation is not license to do so. Either way, whenever Claude holds `full_lifecycle` (the Orchestrator) it keeps classification, DISCOVER, evidence, plan, freezes, the bounded-fix decisions, the quality gate, the completion report, delivery and cleanup — and cannot advance the lifecycle without the evidence and independent gates the run's pipeline requires.
- Independence: REVIEW, QA and VERIFY are recorded by `independent_reviewer`, `independent_qa` and `independent_verifier` sessions; implementation never self-certifies, and a self-authored pass is rejected when the mode requires independence.
- Delivery: `CODE_DONE` does not authorize commits, pushes, PRs or task-system writes. `agent.sh delivery-check` is local-only; provider mutations require explicit authorization.

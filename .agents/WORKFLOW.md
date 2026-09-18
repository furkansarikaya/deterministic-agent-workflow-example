# Deterministic workflow

The checked-in golden template has no active task: `ACTIVE_RUN` is intentionally empty and implementation is blocked. For an application task, it must contain exactly one valid run ID.

```text
CREATE TASK → ACTIVATE RUN → ESTABLISH TASK BRANCH → RECORD BASELINE → DISCOVER → EVIDENCE FREEZE → PLAN → PLAN FREEZE → FRESHNESS GATE → IMPLEMENT → VERIFY → REVIEW → CODE DONE → DELIVERY READY
                                                                                        ↓ fail
                                                                            CAPTURE EVIDENCE → BOUNDED FIX → VERIFY
```

`agent.sh branch <TASK-ID>` must run before `baseline` for any run whose `RUN.yaml` declares
`repository.task_branch` (every run created from here on). It creates
`task/<TASK-ID>-<slug>` from the canonical integration branch's exact tip and switches to
it; every later mutating command (`baseline`, `freeze`/`refreeze`, `handoff`, `verify-scope`,
`delivery-check`) then requires the working tree to still be on that exact branch. See
`.agents/GIT.md` for the full policy, naming algorithm, resume semantics, and legacy-run
handling — it is deliberately not restated here.

DISCOVER is read-only and uses progressive disclosure: start with TASK plus the smallest sufficient repository/tests. Load detailed control guidance only when the current operation needs it; do not bulk-load `.agents/**`, wiki pages, old runs, or session history. Query task-relevant wiki knowledge only when TASK/repository/tests are insufficient. Never edit application/tests/wiki, install dependencies, or broadly refactor in DISCOVER.

At task start, run `./scripts/agent.sh baseline <TASK-ID>` before DISCOVER. It records `repository.base_sha` and SHA-256 fingerprints of pre-existing dirty regular files, without recording their contents. Scope verification ignores an unchanged baseline file but treats later changes to it as task-introduced; the plan must authorize those changes. It refuses symlinks and special files rather than following them.

Application scope is the frozen PLAN mapping and must map to acceptance criteria. The current run’s known workflow artifacts (`TASK.md`, `EVIDENCE.md`, `PLAN.md`, `RUN.yaml`, `RESULT.md`, approved amendments, and the two review artifacts) are separate control metadata: they may change without application-scope mappings, but no other run artifact is allowed. Freeze integrity still rejects post-freeze TASK/EVIDENCE/PLAN mutation.

Before IMPLEMENT, `TASK.md`, `EVIDENCE.md`, `PLAN.md`, and effective mode policy must be hashed in `RUN.yaml`; `agent.sh verify-freeze` must pass. The plan’s YAML `scope` is the complete path boundary and every path maps to acceptance IDs. A changed path outside it blocks DONE.

`agent.sh freshness <TASK-ID>` also requires the planning base SHA and task-source revision to remain current. Local Markdown tasks require a repository-relative, regular, non-symlink `task_source.path`; freeze records that source file's hash. `type: none` with `revision: not_applicable` is valid when no source revision exists. A stale base or source blocks IMPLEMENT until the existing amendment and re-freeze path completes.

Missing information follows: `IMPLEMENT → DISCOVER AMENDMENT → amendments/<sequence>-<reason>.md → new evidence/plan version → explicit re-freeze → IMPLEMENT`. Material scope, API, architecture, evidence-conflict, or irreversible-action decisions are amendments; routine details already implied by the frozen plan are implementation work. Do not mutate frozen history silently. Default bounded fixes: two. Capture the failed command/evidence, target a correction, rerun the failed check, then rerun required verification. Handoff order is `PLANNED → IMPLEMENTING → VERIFIED → REVIEWED → CODE_DONE → DONE`; only a stale-patch recovery may return from REVIEWED to VERIFIED, which resets downstream evidence. `agent.sh handoff` records a task-owned patch fingerprint for VERIFIED, REVIEWED, and CODE_DONE; a changed patch invalidates only those downstream gates. Reviewer context is normally TASK/criteria, frozen evidence/plan references, relevant diff/tests, and required constraints; verifier context is smaller still—criteria, commands/results, and scope/diff evidence. CODE DONE grants no remote permission: `agent.sh delivery-check` only proves local delivery readiness, and provider-specific commit/push/PR actions require explicit authorization. CODE DONE is not KNOWLEDGE DONE; wiki writes happen only in Transaction B.

## Execution topology: standalone vs. orchestrated

Execution topology and agent role are different concepts. Role
(`full_lifecycle` / `implementation_worker`, `AGENT_ROLE`) says what a given
invocation may do; topology says whether a run needs a *second*, delegated
implementation owner at all. The generic control plane defines exactly two
topologies and does not bind either one to a vendor:

- **`standalone`** — the active `full_lifecycle` agent (any agent, any
  vendor — the control plane does not know or care which) owns the entire
  lifecycle itself, including RED, GREEN, and optional REFACTOR. No
  `implementation_worker` delegation happens or is expected.
- **`orchestrated`** — `full_lifecycle` acts as orchestrator only. RED,
  GREEN, scoped REFACTOR, and review-requested fixes belong to
  `implementation_worker`; the orchestrator must not implement application
  code itself.

A run resolves its topology from `RUN.yaml`'s `execution.topology` (`agent.sh resolve_topology`) when set to a valid value, otherwise from `.agents/config.yaml`'s `default_topology` — this reference repository defaults to `standalone` (see `.agents/config.yaml`'s own comment for why). Resolution fails closed if neither is a valid value; it never guesses.

## Implementation ownership: mechanically bound to the resolved topology

In both topologies, `full_lifecycle` owns task initialization, DISCOVER, EVIDENCE, PLAN, freeze, lifecycle orchestration, independent verification, review, the knowledge transaction, completion reporting, and delivery orchestration. What differs is *who may author RED/GREEN/REFACTOR/fix implementation evidence*: `agent.sh expected_implementation_owner(topology)` resolves that to `full_lifecycle` for `standalone` or `implementation_worker` for `orchestrated` — this is the only place a topology is translated into a role expectation, and nothing in the generic control plane hardcodes a vendor identity onto either role.

This is mechanically enforced, not merely documented, for any run whose `RUN.yaml` carries the `worker_evidence:`/`tdd:`/`completion_report:` key blocks (every run created after this policy; a run frozen before it, such as `EXAMPLE-001`, is never retroactively edited to add them and is exempt — the same grandfather pattern already used for `repository.task_branch`). For such a run, `agent.sh handoff <ID> VERIFIED` requires, for every frozen scope path without a validated `tdd_exemption`, at least one valid RED (`result: fail`, a specific non-generic `expected_failure`) and at least one valid GREEN-or-FIX (`result: pass`) evidence file **authored by the role the resolved topology expects** and bound to the *currently frozen* task/evidence/plan hashes — see `agent.sh worker-evidence` / `agent.sh verify-worker-evidence`. Evidence from the *other* role is rejected exactly like stale or cross-task evidence (an orchestrator cannot author orchestrated-mode evidence; a delegated worker cannot author standalone-mode evidence). A `full_lifecycle` orchestrator that edits application files directly under `orchestrated` topology and then tries to advance to VERIFIED without worker evidence is rejected at that transition — this is the concrete fix for the bypass a `full_lifecycle` session demonstrated in practice before this policy existed. Standalone topology is never a loophole: `full_lifecycle` still must record valid RED/GREEN evidence for its own implementation before VERIFIED, under its own role.

Residual limit, stated plainly: a script cannot cryptographically prove which process recorded a given evidence file — the acting role remains a declared claim in both directions (a `full_lifecycle` orchestrator could still export `AGENT_ROLE=implementation_worker` itself under `orchestrated`, exactly as it could claim `AGENT_ROLE=full_lifecycle` under `standalone`), exactly like every other role check in `.agents/ENFORCEMENT.md`. `agent.sh worker-evidence` narrows this by optionally cross-checking a recorded `codex_session_id` against a real local Codex session log when one is discoverable, but does not close it. What *is* closed mechanically: evidence must be structurally valid, belong to the exact task, be authored by the role the resolved topology expects, and be bound to the exact currently-frozen plan/evidence/task hashes (stale or cross-task evidence is rejected), and the lifecycle cannot advance past IMPLEMENT without it.

## TDD: RED → GREEN → REFACTOR as execution evidence, mode-independent

For a policy-enforced run, every scope path is either TDD-covered (RED+GREEN evidence, above, authored by the topology's expected implementation owner) or carries an explicit `tdd_exemption: "<reason>"` in `PLAN.md`'s scope entry. An exemption reason must be specific (≥20 characters) and not a stock phrase (`agent.sh` rejects `"tdd not needed"`, `"configuration change"`, and similar non-answers outright) — this check, and the RED/GREEN requirement itself, behave identically regardless of topology; only *which role* must author the evidence changes. REFACTOR evidence (`agent.sh worker-evidence <ID> REFACTOR pass`) records that a bounded cleanup pass stayed inside frozen scope with tests still green; it is optional and never substitutes for RED/GREEN, in either topology.

## Task Completion Report and DONE

`CODE_DONE` is not the end state for a policy-enforced run. `DONE` additionally requires: `execution.knowledge_state` recorded as `KNOWLEDGE_DONE` or `not_applicable` (`agent.sh knowledge-done <ID> [not_applicable]`), a Task Completion Report at `.agents/runs/<ID>/COMPLETION_REPORT.md` meeting a minimum structural bar (`agent.sh publish-completion-report` validates this before publishing), and that report published through a pluggable task-integration adapter (`.agents/task-integrations/<name>.sh`, contract in `.agents/task-integrations/README.md`) and re-verified (`agent.sh verify-completion-report`) — never marked Done and then documented afterward. `agent.sh` never encodes provider-specific logic itself; it only validates structure and calls the adapter's `publish`/`verify` operations. See `scripts/agent.sh`'s `policy_test` for the enforced ordering and rejection cases (executed by `agent.sh test`).

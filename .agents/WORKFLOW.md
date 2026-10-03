# Deterministic workflow

One canonical workflow: a **deterministic orchestrator** drives **bounded specialist roles** through **explicit artifacts** and **independent quality gates**. It is not a swarm. `.agents/ACTIVE_RUN` is empty in the checked-in template — implementation is blocked until it names exactly one valid run.

```text
TASK → CLASSIFY → BRANCH → BASELINE → DISCOVER → EVIDENCE → [ARCHITECT] → PLAN → [QA PLAN] → FREEZE → FRESHNESS → IMPLEMENT
     → IMPLEMENTED → { REVIEW | QA | VERIFY gates the pipeline requires } → CODE_DONE (quality gate) → [knowledge] → REPORT → DONE → CLEANUP → STOP
                                      ↓ a gate fails
                          ORCHESTRATOR DIAGNOSIS → bounded fix (max 2) → the gates run again on the new tree
```

Brackets are conditional on the task's classification. `agent.sh pipeline <TASK-ID>` prints exactly what a run requires.

## Source of truth

1. **Current source code** — authoritative for implementation behavior.
2. **Permanent workflow contracts** (`AGENTS.md`, `CLAUDE.md`, `.agents/**`, except `runs/`) — authoritative for how agents operate.
3. **The active run's artifacts** — the current task's temporary approved state.

There are no completed runs: cleanup deletes runtime artifacts, and nothing left over may override code or contracts.

## Modes and roles

- **Mode** (`.agents/modes/*.yaml`) = what the *session* is permitted to do (memory, wiki writes, swarm, ...). `deterministic` is the default; `explore` and `review` are looser/read-only session modes.
- **Role** (`AGENT_ROLE`) = a bounded responsibility *within the lifecycle*. Roles are logical: one role is neither one file nor a permanent process, and a task does not activate every role. Any agent product (Claude Code, Codex, ...) may hold any role; the default `full_lifecycle` lets one session own the whole lifecycle.

| Role | `AGENT_ROLE` | Does | Must not |
|---|---|---|---|
| **Orchestrator** | `full_lifecycle` | Owns the lifecycle: classifies, picks the pipeline, assigns bounded scopes, consolidates EVIDENCE, writes PLAN, enforces every freeze, diagnoses failures, runs the bounded fix loop, evaluates the quality gate, writes the completion report, cleans up, declares DONE. **Only role that can transition the task or declare DONE.** Keeps its own context small by consuming compact specialist output. | Create uncontrolled delegation chains |
| **Explorer** | `explorer` | Investigates one assignment (objective, allowed scope, expected output, stop condition): relevant code and tests, patterns, dependencies, constraints, affected files, regression risk, conflicting implementations — factual, compact, `path:symbol` references. Returns findings to the Orchestrator, which consolidates them into the single `EVIDENCE.md`. | Implement, modify files, redefine requirements, expand scope, spawn agents |
| **Architect** | `architect` | Only for COMPLEX/CRITICAL: from TASK and frozen EVIDENCE, designs the smallest valid solution (components, boundaries, compatibility, migration, tradeoffs) as the PLAN's `## Architecture` section. | Implement, expand requirements, override evidence, design for hypothetical futures |
| **QA** | `independent_qa` | *Before* implementation: writes `QA_PLAN.md` (acceptance and adversarial scenarios, only the categories that apply). *After*: evaluates the implementation against the frozen QA plan in `QA_REPORT.md` and records the QA gate. Asks: does the behavior meet the acceptance criteria and survive the important edge cases? | Modify production code, weaken criteria after seeing the implementation |
| **Implementer** | `implementation_worker` (or `full_lifecycle` under `standalone`) | The approved implementation: follows the frozen plan, scope and QA plan; smallest correct change; existing patterns; tests only when the plan requires. Stops and returns to the Orchestrator on required work outside frozen scope. | Expand scope, edit QA criteria or frozen evidence, bypass validation, disable tests, weaken security, unrelated cleanup |
| **Reviewer** | `independent_reviewer` | Reviews the actual diff (correctness, maintainability, architecture, conventions, security, needless complexity, scope creep, shortcuts) in `REVIEW.md`; records the REVIEW gate. Never "tests passed, so PASS". | Repair code |
| **Verifier** | `independent_verifier` | Mechanical proof, in `VERIFY.md`: the frozen plan was implemented, required files exist, scope respected, build/tests/lint/validation commands pass; records the VERIFY gate. Asks: did we implement the frozen plan, and can the repository prove it? | Change the implementation to obtain a pass |

Every specialist reads only its explicit assignment, the relevant source and the approved run artifacts — never another specialist's conversational state. Reviewer, QA and Verifier report PASS, FAIL or BLOCKED; BLOCKED (tooling/environment prevented evaluation) records no gate and returns to the Orchestrator. Failures always return to the Orchestrator.

**No swarm, no recursion.** Specialists never spawn agents, coordinate freely or change task state; communication is only *Orchestrator → bounded assignment → specialist → owned artifact or structured result → Orchestrator*. Exploration may run in parallel only for independent objectives, at most `max_explorers` for the class (`.agents/config.yaml`). Implementation concurrency is exactly one worker; overlapping concurrent edits and parallel implementation do not exist. An `AGENT_ROLE` other than `full_lifecycle` obeys its row above and can run only the CLI commands its role allows (see `.agents/ENFORCEMENT.md`).

## Pipeline selection

The Orchestrator classifies the task with `agent.sh classify <TASK-ID> <CLASS> [review]` before DISCOVER, using these criteria. **The highest class any indicator reaches wins; when unsure between two, take the higher.** Reclassifying (allowed before CODE_DONE) voids the freeze until an amendment and `refreeze`.

| Class | Indicators (any one places the task here) | Typical examples |
|---|---|---|
| **TRIVIAL** | *All* of: ≤ 2 scope paths (script-enforced); no behavior change to executable code; no design choice; no public contract, persistence, security or concurrency involvement | typo, comment, tiny deterministic doc/config change |
| **STANDARD** | Bounded behavior change or fix confined to one component; no new integration; no persistence/messaging change; no security boundary | ordinary feature, bounded bug fix, localized API behavior |
| **COMPLEX** | ≥ 2 modules/layers; new integration or dependency; public API/contract change; persistence, schema or messaging change; meaningful concurrency; significant refactor; a design choice with real tradeoffs | new integration, cross-module change |
| **CRITICAL** | Authentication, authorization, cryptography, secrets/credentials, any security boundary; destructive or irreversible migration; financial/data-integrity-critical behavior; major concurrency/idempotency; high-impact infrastructure, CI or deploy | login, permissions, data migration |

STANDARD opts into a REVIEW gate (`classify <ID> STANDARD review`) when a risk indicator applies: shared code other components use, changed validation/error handling, or behavior others depend on.

The class table is `pipelines:` in `.agents/config.yaml` (evidence, QA, review, architect and `max_explorers` per class). The VERIFY gate applies to every class. `agent.sh` derives from it which artifacts freeze, which run files are legal, which gates `CODE_DONE` needs and which completion-report sections are required. CRITICAL is not "unlimited agents": it is COMPLEX's gates plus wider bounded exploration. `freeze.pipeline` records the class, so a changed class FAILS `verify-freeze` until amended.

## Runtime artifacts

State for one task lives in `.agents/runs/<TASK-ID>/`, is **temporary working state** (gitignored) and is never permanent documentation. Only artifacts the pipeline requires exist; there are no placeholders, and no file without a downstream consumer (`agent.sh` rejects an unrequired `EVIDENCE.md`, `QA_PLAN.md`, `REVIEW.md`, `QA_REPORT.md` or `VERIFY.md`, and any unknown file, as an unexpected artifact).

| Artifact | Owner | Consumed by | Exists when |
|---|---|---|---|
| `RUN.yaml` | Orchestrator (via `agent.sh`) | every command | always — lifecycle facts only: classification, state, freeze hashes, handoff fingerprints, completion report receipt |
| `TASK.md` | Orchestrator | every role, freeze | always |
| `EVIDENCE.md` | Explorers' findings, consolidated by the Orchestrator | Architect, QA, Implementer, Reviewer | not TRIVIAL |
| `PLAN.md` | Orchestrator (+ Architect's `## Architecture`) | Implementer, QA, Reviewer, Verifier, scope check | always — YAML `scope:` is the complete path boundary |
| `QA_PLAN.md` | QA | Implementer (read-only), QA | STANDARD and up |
| `REVIEW.md` | Reviewer | REVIEW gate | when REVIEW is required |
| `QA_REPORT.md` | QA | QA gate | STANDARD and up |
| `VERIFY.md` | Verifier | VERIFY gate | always, once verifying |
| `COMPLETION_REPORT.md` | Orchestrator | task-integration adapter (the task's RESULT) | always |
| `amendments/`, `gates/`, `worker-evidence/`, `decisions/`, `LEDGER.log` | Orchestrator / the recording role, via `agent.sh` | freeze, gates, DONE | as used |

Ownership after freeze: TASK, EVIDENCE, PLAN and QA_PLAN are hash-frozen (`verify-freeze`); a gate binds the hash of its role's report, so editing `REVIEW.md`/`QA_REPORT.md`/`VERIFY.md` after its gate voids that gate; lifecycle fields in `RUN.yaml` are sealed by the ledger. A frozen artifact changes only through an amendment and `refreeze`. Never create scratch, notes, analysis, per-agent log, handoff or summary files.

## Freezes

- **Evidence freeze.** After DISCOVER, EVIDENCE is the factual basis for planning. New significant evidence returns to the Orchestrator as an amendment (below) — no silent mutation, no automatic restart.
- **Plan freeze.** IMPLEMENT cannot start until PLAN (executable, scoped, testable — not a design essay) is frozen. Its YAML `scope` is the complete path boundary and every path maps to acceptance criteria.
- **QA freeze.** When required, QA_PLAN is frozen with the plan. The Implementer reads it and never edits it; a QA plan proven objectively invalid returns to the Orchestrator as an amendment.
- **Scope freeze.** A changed path outside frozen scope blocks DONE. If implementation needs one, the Implementer stops and reports the addition, reason and impact; the Orchestrator decides.

`verify-freeze` checks task, evidence, plan, QA plan, effective policy and the frozen pipeline (artifacts a class does not require are recorded `not_required`). `freshness` additionally requires the planning base SHA and the task source's frozen contract to be current.

**Amendment:** `IMPLEMENT → DISCOVER AMENDMENT → amendments/<sequence>-<reason>.md → new evidence/plan → explicit refreeze → IMPLEMENT`. Material scope, API, architecture, evidence-conflict or irreversible-action decisions are amendments; details the frozen plan already implies are implementation work. One amendment file authorizes exactly one refreeze (reuse, path traversal and a no-change refreeze are refused). A refreeze from IMPLEMENTED invalidates every gate (gates also bind the frozen pipeline and policy); a refreeze that changes the task, evidence, plan or QA plan starts a fresh fix budget: findings and the budget bind the whole frozen contract, not the plan alone.

## Discovery, baseline and branch

`agent.sh branch <TASK-ID>` (see `.agents/GIT.md`) precedes `agent.sh baseline <TASK-ID>`, which records `repository.base_sha` and SHA-256 fingerprints of pre-existing dirty regular files (never contents; symlinks and special files are refused). Scope verification ignores an unchanged baseline file and treats a later change to it as task-introduced.

DISCOVER is read-only and follows the progressive-disclosure rule in `AGENTS.md`. DISCOVER MUST NOT edit application, tests or wiki, install dependencies or refactor broadly. Application scope is the frozen PLAN mapping. The run's known artifacts are control metadata, not application scope.

## Execution topology

Role says what an invocation may do; topology says whether a run needs a *second, delegated* implementation owner. Resolved by `resolve_topology` (in `scripts/agent.sh`) from `RUN.yaml`'s `execution.topology`, else `.agents/config.yaml`'s `default_topology`; invalid on both fails closed.

- **`standalone`** — the `full_lifecycle` agent owns RED/GREEN/REFACTOR itself. No worker delegation.
- **`orchestrated`** — the Orchestrator does not implement application code. RED, GREEN, REFACTOR and every review/QA/verification/amendment fix belong to `implementation_worker`, invoked only through `scripts/worker-run.sh`; a failed invocation leaves the task incomplete and never falls back to the Orchestrator implementing it.

`agent.sh expected_implementation_owner(topology)` is the only place a topology becomes a role expectation; the control plane binds neither role to a vendor.

### Implementation evidence and TDD

Every scope path is either TDD-covered or carries an explicit `tdd_exemption` in PLAN.md (≥ 20 characters, not a stock phrase). `agent.sh handoff <ID> IMPLEMENTED` requires, per non-exempt path, a valid RED (`fail`, a specific `expected_failure`) and GREEN/FIX (`pass`) record from `agent.sh worker-evidence`, authored by the role the topology expects and bound to the currently frozen hashes; other-role, stale or cross-task evidence is rejected. REFACTOR evidence is optional and never substitutes. The write is fail-closed (verified non-empty and well-formed, else removed and aborted).

`worker-run.sh` runs `codex exec --sandbox workspace-write` with `AGENT_ROLE=implementation_worker` for that subprocess only. It grants exactly one `--add-dir`: the run's own `worker-evidence/`, because the sandbox denies writes under dot-prefixed directories. It widens nothing else.

Residual: `AGENT_ROLE` is a declared claim. A script cannot prove which process recorded a file. The control plane closes structure, task binding, role expectation and freeze binding mechanically (`.agents/ENFORCEMENT.md`).

## Quality gates and remediation

The handoff ladder is `PLANNED → IMPLEMENTING → IMPLEMENTED → CODE_DONE → DONE`. `IMPLEMENTED` means `agent.sh handoff` accepted implementation evidence and recorded a patch fingerprint of the task-owned tree. While IMPLEMENTED, the independent roles record the gates the pipeline requires. `CODE_DONE` is the **quality gate**: every required gate MUST hold a current pass for the exact final tree. `CODE_DONE` is not task completion and grants no delivery right.

- **Gates bind the exact tree and report.** `agent.sh gate <ID> REVIEW|QA|VERIFY pass|fail` appends `gates/NNN-<GATE>.yaml` and a per-path manifest. The record holds role, patch fingerprint, frozen hashes and the hash of the role's report. The report MUST exist and end in one matching `Verdict:` line. Gates have no required order. Any byte changed after a gate changes the fingerprint and voids every gate. A later fail voids earlier passes on the same tree. The gate MUST belong to the run's pipeline.
- **Independence is enforced.** With `review.independent`, `qa.independent` and `verification.independent_verifier` true (mode `deterministic`), a pass MUST come from `independent_reviewer`, `independent_qa` or `independent_verifier`. A self-authored `full_lifecycle` pass FAILS at record time and at every later transition. A `full_lifecycle` *fail* is always accepted. `implementation_worker`, `explorer` and `architect` MUST NOT author a gate. Independent roles are read-only observers.
- **Findings are bounded contracts.** A failing gate carries `findings`, `fix_instruction` and `fix_scope` (comma-separated frozen-scope paths; whitespace around entries is ignored). The tree is then an open finding: no further gate MAY be recorded on it. Only the Orchestrator reopens implementation, with `handoff <ID> IMPLEMENTING`, for one fix. Returning to `IMPLEMENTED` requires a changed tree whose changed paths all lie in `fix_scope`. The budget is `verification.max_bounded_fix_attempts` (default 2) fixes per frozen contract, counted across all gates.
- **Diagnose before remediating.** A failure returns to the Orchestrator, who classifies it. Implementation defect: bounded fix, then rerun the gates. Plan, evidence, scope or QA-plan defect: amendment and `refreeze`. Invalid expectation: amendment. Environment or tooling problem: BLOCKED. Run the minimum remediation. MUST NOT restart discovery, architecture, planning or QA planning.
- **Remediation is bounded.** When the fix budget is exhausted, the Orchestrator MUST either amend (fresh budget) or end the run with `agent.sh terminate <ID> FAILED|BLOCKED` (`reason` and `evidence` on stdin). `FAILED` is accepted only after the budget is exhausted. `BLOCKED` covers environment, tooling and external blockers. A terminal run accepts no further lifecycle command. The Orchestrator then stops.
- **Orchestrated topology: the tree has one attested owner.** `worker-run.sh` brackets every worker run with `agent.sh window-open` and `window-close` (tree fingerprints before and after, chained). At IMPLEMENTED, CODE_DONE, DONE, every gate, `validate` and `delivery-check`, the tree MUST equal the last attested window's end. An Orchestrator edit to application or test files FAILS. Under `standalone`, `full_lifecycle` MAY change code at any time; the changed fingerprint voids the gates.
- **Manual rewinds are detected.** Every control-plane transition is appended to `LEDGER.log`, a hash chain. The last entry seals a digest of the RUN.yaml lifecycle fields (state, knowledge state, handoff, classification, task-source path and revision, completion report). A hand edit of those fields or of the ledger FAILS every transition, gate, `validate`, `verify-handoff` and `delivery-check`.
- **Reopening a completed run is scripted.** `agent.sh amend <ID>` (`full_lifecycle` only; stdin `reason`, `fix_scope`, `fix_instruction`, `authorized_by`; `plan_change: yes` if the plan changes) works on a `CODE_DONE` or `DONE` run before cleanup and before the delivery commit. It records who, why and the prior completion state in `gates/NNN-REOPEN.yaml`, resets fingerprints and the published report, and requires new gates, a new knowledge step and a report with a `## Reopen History` section. After cleanup, a follow-up is a new task.

`scripts/lifecycle-test.sh` (run by `agent.sh test`) is the deterministic regression for classification, artifact rules, gates, independence, the fix loop, terminal outcomes, cleanup, ledger and reopen.

## Completion, delivery and cleanup

`DONE` (the `handoff DONE` transition) additionally requires `agent.sh knowledge-done <ID> [not_applicable]`, a `COMPLETION_REPORT.md` derived from actual run evidence with the sections the run needs (`## Implementation Summary`, `## Verification`, `## Known Limitations / Follow-up`, plus `## Review Result` / `## QA Result` when those gates ran, `## TDD Evidence`, `## Amendments`, `## Reopen History` as applicable), and that report published and re-verified (`publish-completion-report`, `verify-completion-report`) through a task-integration adapter (`.agents/task-integrations/`). `agent.sh` stays task-system agnostic and never marks Done and documents afterward.

`agent.sh delivery-check` proves local delivery readiness (freshness, application-scope and knowledge-scope integrity, fingerprints); it never mutates a remote. Commit, push, PR and task-system writes need explicit authorization after it.

**Cleanup.** The last act, after DONE and `delivery-check`: `agent.sh cleanup <TASK-ID>` re-verifies a DONE run, deletes `.agents/runs/<TASK-ID>/` and clears `ACTIVE_RUN`. The published completion report and the repository's own history are the durable record; no run artifact is promoted into permanent documentation. The task is reported DONE to the user only after cleanup succeeds; then STOP. A FAILED/BLOCKED run is retained until the Orchestrator has reported its evidence, then cleaned up the same way.

Between CODE_DONE and cleanup sits an optional durable-information boundary — the knowledge transaction below — and nothing about it is coupled to cleanup.

## Task-source contract: the frozen task is never silently re-baselined

The recorded `task_source.revision` of a local Markdown task source hashes a deterministic projection of the file, not the whole file. The projection drops every `**Status:**` value, drops the single well-formed completion-report block for this task (a `## Completion Report` heading, optional blank lines, `<!-- COMPLETION-REPORT:BEGIN:<TASK-ID> -->` … `<!-- COMPLETION-REPORT:END:<TASK-ID> -->`), and ignores trailing blank lines. Everything else is contract: requirements, criteria, scope, a second block, text after `END`, a block for another task, a heading without markers, an unclosed block.

- Only `freeze` and `refreeze` write the revision. `publish-completion-report` MUST NOT.
- A Status change and the report block are bookkeeping and need no re-baseline. The file's *location* (`in-progress/` → `done/`) changes only through `agent.sh task-source-relocate <ID> <NEW-PATH>` (`full_lifecycle` only). The contract at the new path MUST hash to the recorded revision, the old path MUST be gone (a move, not a copy), and the command is ledgered. It FAILS once the report is published, because the receipt binds the location.
- The `**Status:**` value MUST agree with the lifecycle folder of the task source (`backlog/`, `todo/`, `in-progress/`, `done/`). A task source outside those folders is not checked. `freeze`, `refreeze`, `freshness` and every command that calls it FAIL on a mismatch. `agent.sh task-source-status <ID>` (`full_lifecycle` only) rewrites only that line to the folder's value. It FAILS if the frozen contract would change or once the report is published. A Status-only change is not scope drift: `verify-scope` ignores a change to the recorded task source whose contract still hashes to the frozen revision.
- Fail closed: `freshness`, `handoff`, `gate`, `knowledge-done`, `publish-completion-report`, `delivery-check` and `validate` reject a changed contract. `publish-completion-report` checks freshness before and after the adapter and restores the task source byte for byte if the adapter changed anything outside its block.
- `task_source.path` and `revision` are in the ledger digest.

## Knowledge transaction scope

The knowledge transaction is **optional**: run it only when the task changed a durable project contract or documented architecture. Otherwise record `knowledge-done <ID> not_applicable`. Ordinary evidence, plans, QA and review content is never promoted into permanent documentation.

`PLAN.md`'s `scope:` is Transaction A (application/code) only. Transaction B (wiki writes strictly after CODE_DONE) has its own boundary: `.agents/config.yaml`'s `knowledge_scope_root` (`docs/wiki/`), a single directory-prefix allowlist. A path under it is never application scope; a path outside it always is, whatever `knowledge_state` says.

Two independent checks apply at `DONE`, `delivery-check` and `validate`: **application-scope integrity** (`handoff.code_done_patch_sha256` still matches, and nothing outside application plus knowledge scope changed) and **knowledge-transaction integrity** (`agent.sh verify-knowledge-scope`: a knowledge-scope diff is legitimate only with `knowledge_state = KNOWLEDGE_DONE`; `KNOWLEDGE_DONE` with zero diffs also fails — `not_applicable` is correct when nothing was written). Every earlier phase keeps strict application-only checking, so a wiki write before CODE_DONE is rejected. Regression: `agent.sh test` (`knowledge_scope_test`, `delivery_check_knowledge_scope_test`, `validate_knowledge_scope_test`).

## Execution policy

One resolver decides how a run executes: `scripts/exec-policy.sh`, configured by `execution_policy:` in `.agents/config.yaml`. Only `agent.sh decide <ID> <PHASE>` (`full_lifecycle`) calls it. It is a pure function: no model call, no clock, no run state. The same class, scope evidence, policy `revision`, provider capability set and overrides always yield the same **decision**, one per attempt, persisted as `runs/<ID>/decisions/<epoch>-<PHASE>-<seq>.decision` (`key=value`, with a `*_reason` code per dimension). `exec-policy.sh explain` renders a decision as text. The task class (`pipelines:`) is the primary input. The retry bound is `verification.max_bounded_fix_attempts`: the one retry system.

**Precedence, top wins:**
1. Hard limits: `execution_policy.hard`, the class explorer bound, the retry bound, forbidden efforts (`ultra` = automatic delegation).
2. Explicit operator override (`--model/--effort/--delegation/--context-bytes`; never a config default).
3. Deterministic task policy: class tier, effort and context budget; sensitive scope paths raise the tier; wide scope raises effort and context.
4. Provider capability validation: ladder, supported efforts, unavailable models.
5. The resolved decision.

An invalid override is rejected (exit 3), never reinterpreted. A numeric override above a hard ceiling is clamped with a recorded code. A derived value the model cannot represent is raised or clamped with a recorded `normalization` code. Nothing resolvable is a hard failure (exit 4).

**Topology.** Under `orchestrated`, `worker-run.sh` translates the decision into `codex exec --model … --config model_reasoning_effort=…` and reads none of them from `~/.codex/config.toml`. Under `standalone`, the session owner controls model and effort because the repository cannot change a running session. The decision records `model=session` and rejects model and effort overrides. Context, planning, delegation and validation still resolve. Model choice is the cheapest ladder entry at or above the required tier, never below. The operator declares the ladder order.

**Escalation** is a new decision, not a mutation. `worker-run.sh … --failure <CODE>`:
- `TRANSIENT`: retry unchanged.
- `INSUFFICIENT_REASONING`: raise effort, then model.
- `INSUFFICIENT_CAPABILITY`: raise model, then effort.
- `CONTEXT_MISSING`: double the context budget.
- `SCOPE_VIOLATION`, `POLICY_VIOLATION`: not retryable.

A dimension pinned by an override or at its ceiling cannot escalate. When none can, or `hard.max_escalations` or the attempt bound is reached, the attempt is refused. An amendment starts a fresh attempt epoch, like its fresh fix budget.

**Context and cache.** A worker prompt is a stable, run-independent prefix (`execution_policy.context.stable`, byte-identical across attempts and tasks), then this attempt's dynamic suffix. The task prompt is the task contract. It is never truncated: over the resolved budget it is refused. A failure log is tail-truncated to the remaining budget or excluded. The decision records what was included, excluded and truncated, and the measured outcome. `codex exec` exposes no cache control, so `cache_control: none` is the only accepted value, the strategy is stable-prefix only, and `cache_ttl=none`. MUST NOT fake a TTL.

**Planning depth, delegation and validation depth** derive from the class pipeline: `minimal`, `lightweight` or `architected`; explorers = min(independent top-level scope areas, class bound, hard cap); the gates the pipeline requires. Delegation stays policy-only, as in the enforcement matrix. `exec-policy.sh check-capabilities` compares the declared ladder with the local Codex model cache.

## Context and token discipline

Bounded specialists keep the Orchestrator's context clean and avoid duplicate investigation. They do not guarantee fewer total tokens.

- The Orchestrator consumes compact evidence, never repository dumps. Explorers summarize with source references. Each specialist gets only relevant context and stops when its assignment is done.
- MUST NOT re-read unchanged large files. Duplicate exploration needs a stated reason.
- Reviewer context: TASK and criteria, frozen evidence and plan references, the relevant diff and tests, required constraints. Verifier context is smaller: criteria, commands and results, scope and diff evidence.
- Machine-facing results are compact structured data (`key: value` YAML, JSON). A fact MUST NOT appear in two run artifacts unless integrity needs it.

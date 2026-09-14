# Deterministic workflow

The checked-in golden template has no active task: `ACTIVE_RUN` is intentionally empty and implementation is blocked. For an application task, it must contain exactly one valid run ID.

```text
CREATE TASK → ACTIVATE RUN → RECORD BASELINE → DISCOVER → EVIDENCE FREEZE → PLAN → PLAN FREEZE → FRESHNESS GATE → IMPLEMENT → VERIFY → REVIEW → CODE DONE → DELIVERY READY
                                                                  ↓ fail
                                                      CAPTURE EVIDENCE → BOUNDED FIX → VERIFY
```

DISCOVER is read-only and uses progressive disclosure: start with TASK plus the smallest sufficient repository/tests. Load detailed control guidance only when the current operation needs it; do not bulk-load `.agents/**`, wiki pages, old runs, or session history. Query task-relevant wiki knowledge only when TASK/repository/tests are insufficient. Never edit application/tests/wiki, install dependencies, or broadly refactor in DISCOVER.

At task start, run `./scripts/agent.sh baseline <TASK-ID>` before DISCOVER. It records `repository.base_sha` and SHA-256 fingerprints of pre-existing dirty regular files, without recording their contents. Scope verification ignores an unchanged baseline file but treats later changes to it as task-introduced; the plan must authorize those changes. It refuses symlinks and special files rather than following them.

Application scope is the frozen PLAN mapping and must map to acceptance criteria. The current run’s known workflow artifacts (`TASK.md`, `EVIDENCE.md`, `PLAN.md`, `RUN.yaml`, `RESULT.md`, approved amendments, and the two review artifacts) are separate control metadata: they may change without application-scope mappings, but no other run artifact is allowed. Freeze integrity still rejects post-freeze TASK/EVIDENCE/PLAN mutation.

Before IMPLEMENT, `TASK.md`, `EVIDENCE.md`, `PLAN.md`, and effective mode policy must be hashed in `RUN.yaml`; `agent.sh verify-freeze` must pass. The plan’s YAML `scope` is the complete path boundary and every path maps to acceptance IDs. A changed path outside it blocks DONE.

`agent.sh freshness <TASK-ID>` also requires the planning base SHA and task-source revision to remain current. Local Markdown tasks use their frozen TASK hash as the source revision; `type: none` with `revision: not_applicable` is valid when no source revision exists. A stale base or source blocks IMPLEMENT until the existing amendment and re-freeze path completes.

Missing information follows: `IMPLEMENT → DISCOVER AMENDMENT → amendments/<sequence>-<reason>.md → new evidence/plan version → explicit re-freeze → IMPLEMENT`. Material scope, API, architecture, evidence-conflict, or irreversible-action decisions are amendments; routine details already implied by the frozen plan are implementation work. Do not mutate frozen history silently. Default bounded fixes: two. Capture the failed command/evidence, target a correction, rerun the failed check, then rerun required verification. `agent.sh handoff` records a task-owned patch fingerprint for VERIFIED, REVIEWED, and CODE_DONE; a changed patch invalidates only those downstream gates. Reviewer context is normally TASK/criteria, frozen evidence/plan references, relevant diff/tests, and required constraints; verifier context is smaller still—criteria, commands/results, and scope/diff evidence. CODE DONE grants no remote permission: `agent.sh delivery-check` only proves local delivery readiness, and provider-specific commit/push/PR actions require explicit authorization. CODE DONE is not KNOWLEDGE DONE; wiki writes happen only in Transaction B.

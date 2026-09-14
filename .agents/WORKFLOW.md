# Deterministic workflow

```text
START → DISCOVER → EVIDENCE FREEZE → PLAN → PLAN FREEZE → IMPLEMENT → VERIFY → REVIEW → CODE DONE
                                                                  ↓ fail
                                                      CAPTURE EVIDENCE → BOUNDED FIX → VERIFY
```

DISCOVER is read-only: inspect the smallest sufficient repository, test, architecture, Git, capability, and task-relevant wiki evidence. Never edit application/tests/wiki, install dependencies, or broadly refactor in DISCOVER.

Before IMPLEMENT, `TASK.md`, `EVIDENCE.md`, `PLAN.md`, and effective mode policy must be hashed in `RUN.yaml`; `agent.sh verify-freeze` must pass. The plan’s YAML `scope` is the complete path boundary and every path maps to acceptance IDs. A changed path outside it blocks DONE.

Missing information follows: `IMPLEMENT → DISCOVER AMENDMENT → amendments/<sequence>-<reason>.md → new evidence/plan version → explicit re-freeze → IMPLEMENT`. Do not mutate frozen history silently. Default bounded fixes: two. Capture the failed command/evidence, target a correction, rerun the failed check, then rerun required verification. Review and verification are separate artifacts. CODE DONE is not KNOWLEDGE DONE; wiki writes happen only in Transaction B.

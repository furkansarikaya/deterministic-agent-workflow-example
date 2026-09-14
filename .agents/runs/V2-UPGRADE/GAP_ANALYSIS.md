# V2 upgrade gap analysis

## Inspection basis

- Baseline repository commit: `7c9eabd`.
- Inspected root entrypoints, all V1 control documents, modes, EXAMPLE-001, architecture, wiki, scripts, Go code, and tests.
- Inspected local vibecosystem source at `/Users/furkansarikaya/claude/vibecosystem`, version 3.4.0: its runtime manifest, Codex adapter, CLI, hook manifest, and relevant role definitions.
- This upgrade is user-directed repository work, not a claim that V1 governed its own bootstrap.

## Requirement matrix

| Requirement | Status | Current behavior | Required correction / enforcement / verification |
|---|---|---|---|
| Operational Codex boot protocol | PARTIAL | Root instructions link to documents but do not select a mode or active task. | Add explicit boot sequence, active-run resolver, no-task behavior, edit permission, and DONE blockers. Validate with control-plane tests. |
| Claude adapter contract | PARTIAL | Claude file is a redirect plus a few restrictions. | Map Claude hooks, memory, planning, review, and knowledge write-back to shared policy. Document platform versus policy limits. |
| Machine-readable control policy | MISSING | Modes exist only as Markdown. | Add `.agents/config.yaml` and mode YAML, resolve with `agent-policy.sh`, test invalid modes. |
| Active task resolution | MISSING | No active-run marker; EXAMPLE-001 is inferred by convention. | Add `.agents/ACTIVE_RUN`, strict resolver, clear/set policy, and failure tests. |
| Hash freezes | MISSING | “Frozen” is prose only; V1 has no cryptographic fingerprints. | Add SHA-256 freeze values and `agent-run.sh freeze/verify-freeze`; tamper tests must fail. |
| Amendment protocol | PARTIAL | Workflow names amendment concept but has no auditable structure. | Add amendment directory/template and re-freeze rules; document immutable prior artifacts. |
| Scope and AC mapping | PARTIAL | Script parses a Markdown path list and ignores criterion mappings, deletions, and rename semantics. | Put YAML scope mappings in plan frontmatter; check all tracked/untracked/deleted paths and mappings mechanically. |
| Engineering decision order | PARTIAL | Generic rules exist. | Add evidence-first procedural lookup order and security/concurrency/schema/user-work rules. |
| Knowledge precedence examples | PARTIAL | Priority list exists without conflict examples. | Add concrete conflict-resolution examples. |
| Wiki graph/lint | PARTIAL | Basic links/status/source/orphan checks exist. | Add provenance, one-way/suspicious relationship, contradictions, stale decisions, and task-reference checks; keep non-rewriting behavior. |
| Two transactions | PASS | Documents preserve code then knowledge write-back distinction. | Keep it and connect policy state to tooling. |
| Vibecosystem integration | PARTIAL | V1 names conceptual skills only. | Use actual v3.4.0 `core` profile, its skills and roles; classify memory/orchestration hooks honestly. |
| Capability manifest | MISSING | Run records only two skills and a worker string. | Add resolved allowed/denied capabilities, actual role names, and platform/policy classification. |
| Reviewer/verifier separation | PARTIAL | Result self-reports a review; no separate artifacts or phase evidence. | Add `review/code-review.md` and `review/verification.md`, manifest fields, and verifier checks. |
| Runtime/repository fingerprint | PARTIAL | V1 records a false “unborn” state after the initial commit. | Establish BOOTSTRAP-000 truthfully and reconstruct EXAMPLE-001 at a real baseline SHA without fabricating history. |
| Bootstrap separation | CONFLICT | EXAMPLE-001 claims to create the control plane and records unborn SHA, yet repository has a real initial commit. | Reclassify the prior commit as BOOTSTRAP-000 documentation; make EXAMPLE-001 a small genuine baseline-to-feature task using real SHA. |
| Control-plane tests | MISSING | Only sample application tests exist. | Add Go-independent portable shell fixture tests for policy, active task, freezes, scope, artifacts, and wiki lint. |
| README/architecture onboarding | PARTIAL | Explains concepts but not actual task lifecycle/tools/enforcement boundaries. | Rewrite to show real commands, truthful enforcement matrix, and critical distinctions. |
| Safety / clarification policy | PARTIAL | Basic Git safety exists. | Consolidate prohibitions for credentials, network, destructive operations, dependencies, migrations, and clarification triggers. |

## V2 implementation boundary

The V2 task will create machine policy and tool scripts; migrate bootstrap/example artifacts truthfully; add control-plane test fixtures; and update documentation/wiki metadata needed to explain them. It will not add runtime dependencies, a database, a network service, or a custom agent platform.

## Proposed verification

```bash
./scripts/verify.sh
./scripts/control-plane-test.sh
./scripts/agent-policy.sh effective
./scripts/agent-run.sh status
./scripts/agent-run.sh validate EXAMPLE-001
./scripts/agent-run.sh verify-freeze EXAMPLE-001
./scripts/check-scope.sh EXAMPLE-001
./scripts/wiki-lint.sh
git status --short
git diff --name-only
git diff --stat
```


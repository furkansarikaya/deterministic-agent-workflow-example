# Enforcement matrix

| Rule | Classification | Mechanism |
|---|---|---|
| Active task selection | Script-enforced | An empty checked-in `ACTIVE_RUN` reports `active_task=none`; malformed/missing targets fail and implementation commands require an explicit valid task. |
| Valid mode / effective policy | Script-enforced | `agent.sh effective` reads YAML only from the allowlisted mode directory. |
| Task, evidence, plan, policy freeze | Script-enforced | SHA-256 values in `RUN.yaml`; `agent.sh verify-freeze` rejects mismatch. |
| Planning freshness | Script-enforced for local Markdown/none sources | `agent.sh freshness` validates base SHA and frozen local task revision; unsupported external adapters block rather than invent state. |
| Handoff patch integrity | Script-enforced | `agent.sh verify-handoff` invalidates VERIFIED/REVIEWED/CODE_DONE evidence when the task-owned patch fingerprint changes. |
| Delivery boundary | Script-enforced local gate | `agent.sh delivery-check` never mutates a remote; it requires current freshness, scope, review, verification, and CODE DONE fingerprints. |
| Application scope and AC mapping | Script-enforced | `agent.sh verify-scope` validates task-introduced application paths against PLAN mappings. |
| Current-run control metadata | Script-enforced | Only a strict known-artifact allowlist inside the current run directory is excluded from application scope; arbitrary `.agents/**` files are not. |
| Dirty-worktree baseline | Script-enforced | `agent.sh baseline` stores `repository.base_sha` and regular-file SHA-256 fingerprints. An unchanged user-owned dirty file is excluded; a later change is checked against scope. |
| Required run artifacts | Script-enforced | `agent.sh validate`. |
| Build/tests/static checks | Script-enforced | `verify.sh` and verification artifact. |
| Wiki structural integrity | Script-enforced | `wiki-lint.sh` reports, never rewrites. |
| Progressive context loading | Policy-only | Mode YAML and shared rules require on-demand retrieval, but repository scripts cannot observe an agent's context window. |
| One implementation worker / separate review phases | Workflow-enforced | Manifest plus distinct review artifacts; platform identity is unavailable to this repository. |
| Wiki no-write during code transaction | Policy-only | Repository scripts can detect scope after the fact but cannot intercept editor writes. |
| Memory, recall, prompt improver, learning writes, swarm | Policy-only in this repository | Deterministic policy denies them; installed host hooks/profile selection remain host-controlled. |
| Credential denial | Platform-enforced when vibecosystem core hook is active | Actual `credential-deny` core hook; repository does not assume it is installed. |
| User confirmation for destructive/external actions | Agent/platform policy | Documents require it; scripts do not authorize actions. |

Never describe policy-only behavior as technically disabled.

## Evidence strength

Hashes, policy selection, `repository.base_sha`, and baseline fingerprints are machine-verifiable. Worker roles, worker identity, and reviewer/verifier independence are declared workflow evidence unless the host platform supplies auditable identities. Baseline hashes prove that a file changed after task start, not that an authorized edit semantically preserved every part of user-owned work; reconciliation remains an agent and review obligation.

`EXAMPLE-001` is a historical reference with `baseline.status: legacy_not_captured`; validation accepts that explicit marker, while live scope verification is intentionally unavailable for it. Its recorded policy hash is retained as historical evidence; only this marker permits reporting that the current policy has since changed. Live runs always fail a policy-hash mismatch.

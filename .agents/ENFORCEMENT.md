# Enforcement matrix

| Rule | Classification | Mechanism |
|---|---|---|
| One active deterministic task | Script-enforced | `agent.sh status` rejects blank, malformed, or missing ACTIVE_RUN targets. |
| Valid mode / effective policy | Script-enforced | `agent.sh effective` reads YAML only from the allowlisted mode directory. |
| Task, evidence, plan, policy freeze | Script-enforced | SHA-256 values in `RUN.yaml`; `agent.sh verify-freeze` rejects mismatch. |
| Authorized scope and AC mapping | Script-enforced | `agent.sh verify-scope` validates plan mappings and changed tracked/untracked/deleted paths. |
| Required run artifacts | Script-enforced | `agent.sh validate`. |
| Build/tests/static checks | Script-enforced | `verify.sh` and verification artifact. |
| Wiki structural integrity | Script-enforced | `wiki-lint.sh` reports, never rewrites. |
| One implementation worker / separate review phases | Workflow-enforced | Manifest plus distinct review artifacts; platform identity is unavailable to this repository. |
| Wiki no-write during code transaction | Policy-only | Repository scripts can detect scope after the fact but cannot intercept editor writes. |
| Memory, recall, prompt improver, learning writes, swarm | Policy-only in this repository | Deterministic policy denies them; installed host hooks/profile selection remain host-controlled. |
| Credential denial | Platform-enforced when vibecosystem core hook is active | Actual `credential-deny` core hook; repository does not assume it is installed. |
| User confirmation for destructive/external actions | Agent/platform policy | Documents require it; scripts do not authorize actions. |

Never describe policy-only behavior as technically disabled.

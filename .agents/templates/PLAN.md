---
scope:
  - path: path/to/file
    criteria: [AC-1]
    # Optional. Only set this when RED/GREEN evidence genuinely does not
    # apply to this path (docs-only, metadata-only, pure control-plane
    # config). Must be specific (>=20 chars) and not a generic stock phrase
    # ("tdd not needed", "configuration change", etc.) — agent.sh rejects
    # both at freeze time. Omit the key entirely for any behavior-changing
    # path; it then requires implementation_worker RED+GREEN evidence
    # before IMPLEMENTED (see `worker-evidence` in .agents/VERIFICATION.md).
    # tdd_exemption: "why RED/GREEN does not apply here, specifically"
---

# Plan: <TASK-ID>

The YAML scope lists application paths only. Known artifacts in this run directory are workflow metadata and are validated separately.

Owner: Orchestrator, with the Architect's contribution for COMPLEX and CRITICAL tasks.

## Architecture

Required for COMPLEX and CRITICAL tasks only (delete this section otherwise). The smallest valid design: affected components and boundaries, compatibility and migration concerns, the tradeoffs that matter. No speculative structure.

## Behavior

## Tests

## Verification commands

## Amendment rule

After freeze, an added path or changed constraint requires an amendment under `amendments/`, an updated evidence/plan version, and explicit re-freeze. Never silently alter frozen history.

---
scope:
  - path: path/to/file
    criteria: [AC-1]
    # Optional. Set it only when RED/GREEN evidence does not apply to this path (docs, metadata,
    # control-plane config). The reason MUST be specific: >= 20 characters, no stock phrase.
    # agent.sh rejects both at freeze time. Omit the key for a behavior-changing path: it then
    # needs RED and GREEN evidence before IMPLEMENTED (`worker-evidence` in .agents/VERIFICATION.md).
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

After freeze, a path or constraint changes only through an amendment and `refreeze` (`.agents/WORKFLOW.md` "Freezes").

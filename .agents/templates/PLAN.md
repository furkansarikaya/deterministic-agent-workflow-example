---
scope:
  - path: path/to/file
    criteria: [AC-1]
---

# Plan: <TASK-ID>

The YAML scope lists application paths only. Known artifacts in this run directory are workflow metadata and are validated separately.

## Behavior

## Tests

## Verification commands

## Amendment rule

After freeze, an added path or changed constraint requires an amendment under `amendments/`, an updated evidence/plan version, and explicit re-freeze. Never silently alter frozen history.

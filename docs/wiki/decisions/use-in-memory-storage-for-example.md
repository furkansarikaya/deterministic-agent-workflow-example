---
title: use-in-memory-storage-for-example
status: accepted
source: docs/agent-control-plane.md
---

# Use in-memory storage for example

## Decision

Keep [[task-registry]] state in process memory.

## Why

The repository demonstrates agent controls, not database design. Dependency-free storage keeps verification fast and makes state behavior easy to test.

## Alternatives

A file store would add persistence behavior; a database would add infrastructure and unrelated operational concerns.

## Consequences

Tasks disappear when the process ends. That limitation is intentional and documented by [[architecture-overview]]. EXAMPLE-001 is constrained to focused registry behavior.


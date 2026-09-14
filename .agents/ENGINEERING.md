# Engineering rules

Before creating a pattern: (1) search exact equivalent, (2) inspect neighbors, (3) inspect tests, (4) inspect canonical architecture, (5) inspect wiki decisions, (6) inspect lessons, then (7) introduce only a necessary pattern.

Make the smallest complete change. No speculative abstraction, unrelated cleanup, dependency upgrade, public-contract change, database/schema change, or concurrency behavior change unless task-authorized and planned. Validate inputs; preserve failure semantics, security boundaries, and branch-specific invariants; add regression tests when practical. Never weaken tests or modify unrelated files to satisfy verification. Preserve user-owned work and stop for destructive operations, migrations, credentials, network calls, or material ambiguity.


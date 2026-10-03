# Engineering rules

Before creating a pattern: (1) search exact equivalent, (2) inspect neighbors, (3) inspect tests, (4) inspect canonical architecture, (5) inspect wiki decisions, (6) inspect lessons, then (7) introduce only a necessary pattern.

Make the smallest complete change. No speculative abstraction, unrelated cleanup, dependency version change, public-contract change, database/schema change, or concurrency behavior change unless task-authorized and planned. Validate inputs; preserve failure semantics, security boundaries, and branch-specific invariants; add regression tests when practical. Never weaken tests or modify unrelated files to satisfy verification. Preserve user-owned work and stop for destructive operations, migrations, credentials, network calls, or material ambiguity.

## Controlled language

Write normative text (rules, templates, error messages) in a controlled subset of English, inspired by ASD-STE100. It is not an ASD-STE100 compliance claim.

- Use MUST, MUST NOT, MAY, FAIL and STOP for obligations and outcomes. One declarative sentence states one rule for one actor.
- Use one term per concept: run, task, gate, finding, freeze, amendment, scope, tree, role, topology, projection. Do not add synonyms.
- Use active voice and present tense. Keep sentences short. Do not use filler or hedging.
- Keep identifiers, commands, paths and file names exact.
- Put facts in structured data (`key: value` YAML, JSON). Prose is a projection of the data and MUST NOT add a fact the data lacks.

## Control-plane portability

CONTROL-PLANE PORTABILITY: The control plane MUST NOT impose an application-language toolchain on a consuming repository unless that dependency is part of the documented minimum platform.

The documented minimum platform is POSIX `sh`, `git`, POSIX `awk`, `sed` and `shasum`. `curl` is optional and only emits workflow events. `scripts/verify.sh`, `src/` and `tests/` are the example application. They are not the control plane.

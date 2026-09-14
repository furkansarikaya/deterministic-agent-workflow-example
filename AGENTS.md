# Agent control plane

This repository demonstrates deterministic coding-agent work. Treat `.agents/` as the control plane: read `WORKFLOW.md` first, then the active task, evidence, plan, and relevant mode. `docs/wiki/` is read-only during deterministic code work.

Mandatory rules:

- Inspect before editing; preserve user-owned changes.
- Obey the task and frozen plan scope; make the smallest complete change.
- Do not add dependencies, make autonomous architecture changes, or activate an uncontrolled swarm.
- Verification and final scope/diff inspection are mandatory; stop at DONE.

Detailed rules: `.agents/ENGINEERING.md`, `GIT.md`, `VERIFICATION.md`, and `KNOWLEDGE.md`. Capabilities may come from vibecosystem, but its skills do not override this control plane.


# Shared deterministic workflow for Claude Code

Read and follow the shared control plane in `AGENTS.md` and `.agents/WORKFLOW.md`. Use the same task, evidence, plan, verification, scope-freeze, and DONE gates as Codex. This file deliberately does not duplicate them.

During a deterministic run: do not automatically activate swarm behavior; do not use memory, self-learning, or prompt auto-improvement to change the active run; do not alter task scope autonomously; and keep wiki writes deferred until CODE DONE. Claude-specific conveniences may assist execution only within the frozen contract.


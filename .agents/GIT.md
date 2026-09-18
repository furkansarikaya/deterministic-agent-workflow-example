# Git and safety rules

Inspect `git status --short` before work. User changes are user-owned: do not reset, overwrite, stage, discard, or claim them. For an active task, record them with `./scripts/agent.sh baseline <TASK-ID>` before DISCOVER; this records fingerprints, not contents. No force push, rebase, destructive Git command, credential access/logging, arbitrary network request, destructive migration, or irreversible external action without explicit authorization.

Do not commit unless task execution requires a real baseline or the user requests it. Before DONE inspect status, name-only diff, stat, and actual diff. Every task-owned path must be frozen-authorized and map to an acceptance criterion.

## Deterministic task branch isolation

`.agents/config.yaml`'s `canonical_branch` (currently `main`) is the single authoritative
source for the canonical integration branch — never hardcode `main` elsewhere. A
deterministic task run never implements on that branch directly. Before `baseline`, a new
run must call `./scripts/agent.sh branch <TASK-ID>`, which:

- resolves the canonical branch's exact current tip (never "whatever HEAD is"),
- deterministically derives `task/<TASK-ID>-<slug>` — for a `local_markdown` task source,
  `<slug>` is that source file's own basename with the `<TASK-ID>-` prefix and `.md` suffix
  stripped, so it requires no new title-parsing logic; no timestamps, no random suffixes,
- creates that branch from the canonical tip (or, resuming an already-established run,
  reuses the exact branch already recorded in `RUN.yaml` — it never regenerates a slug or
  creates a second branch for the same run),
- fails closed rather than reusing or overwriting a same-named branch whose tip does not
  match the canonical base, and never deletes, resets, or force-updates any branch,
- switches to it and records `repository.canonical_branch`/`repository.task_branch` in
  `RUN.yaml`.

`baseline`, `freeze`/`refreeze`, `handoff` (every phase), `verify-scope`, and
`delivery-check` all then require the working tree to be on that exact recorded branch —
not merely a `task/`-prefixed branch — and fail closed on the canonical branch, a detached
HEAD, another run's branch, or any other mismatch. `implementation_worker` is additionally
blocked from ever calling `branch` (`require_full_lifecycle`), so a worker can only ever
implement when already on the exact expected branch for the active run.

A `RUN.yaml` with no `repository.task_branch` key at all (every run recorded before this
policy existed, i.e. `EXAMPLE-001`) is legacy: none of the above is retroactively enforced
on it, and it is never rewritten to fabricate branch history it never had. Only a run whose
`RUN.yaml` schema includes that key is held to it. CODE DONE / KNOWLEDGE DONE never merge,
push, delete, or switch off the task branch — completion and delivery remain separate
concerns (`agent.sh delivery-check` is still local-only).

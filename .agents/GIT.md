# Git and safety rules

Inspect `git status --short` before work. User changes are user-owned: do not reset, overwrite, stage, discard, or claim them. No force push, rebase, destructive Git command, credential access/logging, arbitrary network request, destructive migration, or irreversible external action without explicit authorization.

Do not commit unless task execution requires a real baseline or the user requests it. Before DONE inspect status, name-only diff, stat, and actual diff. Every task-owned path must be frozen-authorized and map to an acceptance criterion.


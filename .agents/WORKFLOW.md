# Deterministic workflow

All coding work follows this non-skippable state machine:

```text
START → DISCOVER → EVIDENCE FREEZE → PLAN → PLAN FREEZE → IMPLEMENT → VERIFY → REVIEW → DONE
                                                            ↓ fail
                                                BOUNDED FIX → VERIFY
```

DISCOVER is read-only: inspect the smallest useful set of repository files, tests, architecture, task-relevant wiki pages, permitted skills, and useful Git history. Do not edit code/tests/wiki, install dependencies, or broadly refactor. Before plan or implementation, create `.agents/runs/<TASK-ID>/EVIDENCE.md` referencing repository and wiki evidence. It freezes once IMPLEMENT starts.

PLAN must list files to modify/create/delete, behavior, tests, and verification. At PLAN FREEZE that file list is the task boundary. Each changed file maps to an acceptance criterion. New required information triggers `IMPLEMENT → DISCOVER AMENDMENT → EVIDENCE v2 → PLAN v2 → IMPLEMENT`; do not browse unrelated wiki pages.

VERIFY failures attributable to implementation may use at most two bounded fixes. Feed exact failure evidence into each fix; no blind retry. REVIEW is code review plus independent verifier. Before DONE run `git status --short`, `git diff --name-only`, and `git diff --stat`; unexplained files block DONE. Once acceptance criteria pass, stop—no cleanup, neighboring refactors, or speculative abstractions.


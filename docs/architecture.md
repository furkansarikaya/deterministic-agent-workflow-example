# Architecture

The repository uses engineering determinism, not byte-for-byte model determinism. Given the same repository state, task contract, evidence set, mode, skill set, and verification commands, it seeks the same externally observable behavior and acceptance result.

## Control and capability contract

`.agents` owns state transitions, task boundaries, stop conditions, and proof. vibecosystem is optional and provides skills or roles only. In deterministic mode, allowlist skills, use one implementation worker, then code review and verifier; never auto-start a swarm. Learning found during a run is deferred until CODE DONE and cannot alter current rules. Maximum bounded-fix retries: two; each retry must name prior failure evidence and targeted correction.

Preferred QA flow: `IMPLEMENT → CODE REVIEW → VERIFIER → PASS` or `FAIL → BOUNDED FIX → VERIFY`. A profile exposes capabilities (`core`, `backend`, `security`); a mode limits behavior (`deterministic`, `explore`, `review`). They are separate axes: `profile = core`, `mode = deterministic`.

## Two transactions

Code: `TASK → DISCOVER → WIKI READ → EVIDENCE FREEZE → PLAN FREEZE → IMPLEMENT → VERIFY → REVIEW → CODE DONE`. Wiki is read-only.

Knowledge: `CODE RESULT → SESSION SUMMARY → WIKI INGEST → NEW DECISIONS/LESSONS → WIKI LINT → KNOWLEDGE DONE`. A task cannot rewrite its own past; after completion it may become history used by future tasks.

The sample [[task-registry]] uses [[use-in-memory-storage-for-example]] and guards input as documented by [[validate-input-before-state-change]].


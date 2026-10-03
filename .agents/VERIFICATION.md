# Verification

```sh
./scripts/verify.sh
./scripts/agent.sh test
./scripts/agent.sh effective
./scripts/agent.sh status
./scripts/agent.sh classify <TASK-ID> <TRIVIAL|STANDARD|COMPLEX|CRITICAL> [review]
./scripts/agent.sh pipeline <TASK-ID>
./scripts/agent.sh baseline <TASK-ID>
./scripts/agent.sh validate <TASK-ID>
./scripts/agent.sh verify-freeze <TASK-ID>
./scripts/agent.sh freshness <TASK-ID>
./scripts/agent.sh verify-scope <TASK-ID>
./scripts/agent.sh verify-knowledge-scope <TASK-ID>
./scripts/agent.sh verify-worker-evidence <TASK-ID>
./scripts/agent.sh verify-handoff <TASK-ID>
./scripts/agent.sh verify-completion-report <TASK-ID>
./scripts/agent.sh delivery-check <TASK-ID>
./scripts/agent.sh cleanup <TASK-ID>
./scripts/agent.sh summary [TASK-ID]
./scripts/agent.sh report [TASK-ID] [--out FILE]
./scripts/agent.sh oversight-model [TASK-ID]
./scripts/wiki-lint.sh
```

The Verifier records commands and results in `VERIFY.md` as ``- `command` | exit=N`` lines and the VERIFY gate (`agent.sh gate <TASK-ID> VERIFY pass|fail`); the Reviewer's `REVIEW.md`, QA's `QA_REPORT.md` and their gates are separate (see `.agents/WORKFLOW.md`). Failure follows the bounded fix loop; never weaken checks.

`./scripts/agent.sh test` runs, in order: `fixture_test` (base state machine — freeze, freshness, scope, handoff, delivery), `scripts/lifecycle-test.sh` (classification and pipelines, REVIEW/QA/VERIFY gates and report binding, independence, mutation ownership, the bounded fix loop, terminal outcomes and cleanup, ledger, reopen, task-source contract; both topologies), `branch_test` (task-branch isolation), `policy_test` (`orchestrated` topology — an orchestrator implementation bypass, orchestrator-authored, stale, cross-task or out-of-scope worker evidence are rejected; a valid TDD exemption substitutes for RED/GREEN; DONE needs a published, verified completion report), `standalone_test` (the same requirements with zero delegation, and `worker-run.sh` refusing a standalone run), `worker_evidence_write_failure_test` (`worker-evidence` fails closed on a denied write), `knowledge_scope_test` / `delivery_check_knowledge_scope_test` / `validate_knowledge_scope_test` (application-scope and knowledge-scope integrity at DONE, delivery-check and validate), and `wiki_lint_self_scan_test`. `scripts/oversight-model-test.sh` (model, report, roles, escaping, events, large run) and `scripts/oversight-test.sh` (end to end, restricted-PATH portability) cover the oversight layer (`.agents/OVERSIGHT.md`). `./scripts/agent.sh role-test` proves the `implementation_worker` role boundary itself.

For a policy-enforced run, record implementation evidence with the role the run's resolved execution topology expects (`resolve_topology` (in `scripts/agent.sh`) / `expected_implementation_owner` — `full_lifecycle` under `standalone`, `implementation_worker` under `orchestrated`; the other role is rejected):

```sh
printf 'command: <the exact test command run>\ntarget: <comma-separated scope paths>\nexpected_failure: <RED only — specific behavioral reason>\n' \
  | AGENT_ROLE=<expected-role> ./scripts/agent.sh worker-evidence <TASK-ID> <RED|GREEN|REFACTOR|FIX> <pass|fail>
```

Under `orchestrated` topology, `scripts/worker-run.sh` is the canonical way to invoke Codex as that worker — see `README.md`. Under `standalone` topology, no separate invocation mechanism exists: the active `full_lifecycle` session runs the command above itself, under its own default role.

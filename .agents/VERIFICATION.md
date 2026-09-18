# Verification

```sh
./scripts/verify.sh
./scripts/agent.sh test
./scripts/agent.sh effective
./scripts/agent.sh status
./scripts/agent.sh baseline <TASK-ID>
./scripts/agent.sh validate <TASK-ID>
./scripts/agent.sh verify-freeze <TASK-ID>
./scripts/agent.sh freshness <TASK-ID>
./scripts/agent.sh verify-scope <TASK-ID>
./scripts/agent.sh verify-worker-evidence <TASK-ID>
./scripts/agent.sh verify-handoff <TASK-ID>
./scripts/agent.sh verify-completion-report <TASK-ID>
./scripts/agent.sh delivery-check <TASK-ID>
./scripts/wiki-lint.sh
```

The verifier records commands and results in `review/verification.md`. Failure follows bounded fix; never weaken checks.

`./scripts/agent.sh test` runs four fixture suites: `fixture_test` (base state machine), `branch_test` (task-branch isolation), `policy_test` (`orchestrated` topology — proves a `full_lifecycle` orchestrator implementation bypass is rejected, evidence authored by the orchestrator itself is rejected, stale/cross-task/out-of-scope worker evidence is rejected, a valid TDD exemption substitutes for RED/GREEN, and DONE requires a published, independently-verified completion report in that order), and `standalone_test` (`standalone` topology — proves the same RED/GREEN/TDD-exemption/completion-report/DONE requirements hold with zero delegation, authored by `full_lifecycle` itself, and that `worker-run.sh` refuses to run against a standalone run). `./scripts/agent.sh role-test` proves the `implementation_worker` role boundary itself.

For a policy-enforced run, record implementation evidence with the role the run's resolved execution topology expects (`agent.sh resolve_topology` / `expected_implementation_owner` — `full_lifecycle` under `standalone`, `implementation_worker` under `orchestrated`; the other role is rejected):

```sh
printf 'command: <the exact test command run>\ntarget: <comma-separated scope paths>\nexpected_failure: <RED only — specific behavioral reason>\n' \
  | AGENT_ROLE=<expected-role> ./scripts/agent.sh worker-evidence <TASK-ID> <RED|GREEN|REFACTOR|FIX> <pass|fail>
```

Under `orchestrated` topology, `scripts/worker-run.sh` is the canonical way to invoke Codex as that worker — see `README.md`. Under `standalone` topology, no separate invocation mechanism exists: the active `full_lifecycle` session runs the command above itself, under its own default role.

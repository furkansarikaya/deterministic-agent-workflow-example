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

`./scripts/agent.sh test` runs three fixture suites: `fixture_test` (base state machine), `branch_test` (task-branch isolation), and `policy_test` (worker-evidence, TDD, and completion-report enforcement — proves a `full_lifecycle` implementation bypass is rejected, stale/cross-task/out-of-scope worker evidence is rejected, a valid TDD exemption substitutes for RED/GREEN, and DONE requires a published, independently-verified completion report in that order). `./scripts/agent.sh role-test` proves the `implementation_worker` role boundary itself.

For a policy-enforced run, record implementation_worker evidence with:

```sh
printf 'command: <the exact test command run>\ntarget: <comma-separated scope paths>\nexpected_failure: <RED only — specific behavioral reason>\n' \
  | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence <TASK-ID> <RED|GREEN|REFACTOR|FIX> <pass|fail>
```

`scripts/worker-run.sh` is the canonical way to invoke Codex as that worker — see `README.md`.

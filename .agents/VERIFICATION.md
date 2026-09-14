# Verification

```sh
./scripts/verify.sh
./scripts/agent.sh test
./scripts/agent.sh effective
./scripts/agent.sh status
./scripts/agent.sh baseline <TASK-ID>
./scripts/agent.sh validate <TASK-ID>
./scripts/agent.sh verify-freeze <TASK-ID>
./scripts/agent.sh verify-scope <TASK-ID>
./scripts/wiki-lint.sh
```

The verifier records commands and results in `review/verification.md`. Failure follows bounded fix; never weaken checks.

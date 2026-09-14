# Verification

```sh
./scripts/verify.sh
./scripts/control-plane-test.sh
./scripts/agent-policy.sh effective
./scripts/agent-run.sh status
./scripts/agent-run.sh validate <TASK-ID>
./scripts/agent-run.sh verify-freeze <TASK-ID>
./scripts/check-scope.sh <TASK-ID>
./scripts/wiki-lint.sh
```

The verifier records commands and results in `review/verification.md`. Failure follows bounded fix; never weaken checks.


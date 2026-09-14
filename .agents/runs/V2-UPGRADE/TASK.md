# Task: V2-UPGRADE

## Objective

Upgrade the V1 example into an auditable deterministic workflow golden reference while preserving the dependency-free Go application.

## Allowed scope

Control-plane configuration and documents, run artifacts, scripts, control-plane tests, architecture/readme/wiki policy pages, and the small example task/test needed to demonstrate the V2 run.

## Forbidden scope

No dependency additions, database, network service, custom orchestration runtime, destructive Git operation, credential capture, or invented vibecosystem capabilities.

## Acceptance criteria

- AC-1: Operational Codex and Claude boot adapters resolve one explicit active run.
- AC-2: Machine-readable policy, effective-policy output, freeze hashes, amendments, and run validation work.
- AC-3: Scope paths map to acceptance criteria and unexpected paths fail mechanically.
- AC-4: Actual vibecosystem v3.4.0 integration is documented with honest enforcement classes.
- AC-5: Separate bootstrap and genuine EXAMPLE-001 artifacts use real repository SHA(s), review, and verifier evidence.
- AC-6: Wiki rules/lint, documentation, application tests, and control-plane tests pass.

## Verification commands

```sh
./scripts/verify.sh
./scripts/control-plane-test.sh
./scripts/agent-policy.sh effective
./scripts/agent-run.sh validate EXAMPLE-001
./scripts/agent-run.sh verify-freeze EXAMPLE-001
./scripts/check-scope.sh EXAMPLE-001
./scripts/wiki-lint.sh
```


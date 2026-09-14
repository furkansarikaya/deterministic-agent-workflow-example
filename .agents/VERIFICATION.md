# Verification

This Go example has no external dependencies. For every implementation task run:

```bash
./scripts/verify.sh
./scripts/check-scope.sh .agents/runs/<TASK-ID>/PLAN.md
git status --short
git diff --name-only
git diff --stat
```

`verify.sh` runs `go build ./...`, `go test ./...`, and `go vet ./...` with fail-fast behavior. A failed check enters the bounded-fix path in `WORKFLOW.md`.


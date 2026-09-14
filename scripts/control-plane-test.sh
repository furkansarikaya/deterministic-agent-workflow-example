#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/deterministic-control.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.agents/runs/FIX/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/docs/wiki"
cp "$root/scripts/agent-policy.sh" "$root/scripts/agent-run.sh" "$root/scripts/check-scope.sh" "$root/scripts/wiki-lint.sh" "$tmp/scripts/"
cp "$root/.agents/config.yaml" "$tmp/.agents/"
cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
printf 'FIX\n' > "$tmp/.agents/ACTIVE_RUN"
printf '# Task\n' > "$tmp/.agents/runs/FIX/TASK.md"
printf '# Evidence\n' > "$tmp/.agents/runs/FIX/EVIDENCE.md"
printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '  - path: .agents/runs/FIX/RUN.yaml' '    criteria: [AC-1]' '  - path: .agents/runs/FIX/amendments/001.md' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/FIX/PLAN.md"
printf '%s\n' 'execution:' '  mode: deterministic' '  profile: core' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' > "$tmp/.agents/runs/FIX/RUN.yaml"
printf '# review\n' > "$tmp/.agents/runs/FIX/review/code-review.md"
printf '# verification\n' > "$tmp/.agents/runs/FIX/review/verification.md"
printf '# result\n' > "$tmp/.agents/runs/FIX/RESULT.md"
(
  cd "$tmp"
  git init -q
  git config user.email fixture@example.invalid
  git config user.name fixture
  : > authorized.txt
  git add -- .agents scripts docs authorized.txt
  git commit -qm baseline
  ./scripts/agent-run.sh freeze FIX
  ./scripts/agent-run.sh verify-freeze FIX
  cp .agents/runs/FIX/EVIDENCE.md evidence.original
  printf 'tamper\n' >> .agents/runs/FIX/EVIDENCE.md
  if ./scripts/agent-run.sh verify-freeze FIX; then echo 'tampered evidence unexpectedly passed' >&2; exit 1; fi
  mv evidence.original .agents/runs/FIX/EVIDENCE.md
  mkdir -p .agents/runs/FIX/amendments
  printf '# amendment\n' > .agents/runs/FIX/amendments/001.md
  ./scripts/agent-run.sh refreeze FIX 001.md
  printf 'change\n' > authorized.txt
  ./scripts/check-scope.sh FIX
  printf 'unexpected\n' > unexpected.txt
  if ./scripts/check-scope.sh FIX; then echo 'unexpected path unexpectedly passed' >&2; exit 1; fi
  rm unexpected.txt
  printf 'MISSING\n' > .agents/ACTIVE_RUN
  if ./scripts/agent-run.sh status; then echo 'missing active task unexpectedly passed' >&2; exit 1; fi
  printf 'FIX\n' > .agents/ACTIVE_RUN
  printf '# index\n[[missing]]\n' > docs/wiki/index.md
  if ./scripts/wiki-lint.sh; then echo 'broken wiki link unexpectedly passed' >&2; exit 1; fi
)
echo 'control-plane tests passed'

#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
run_dir() { printf '%s/.agents/runs/%s\n' "$root" "$1"; }
config_value() { sed -n "s/^$1: *//p" "$2" | head -n 1 | tr -d '"'; }

active_run() {
  marker=$root/$(config_value active_run_file "$config")
  [ -f "$marker" ] || { echo "ACTIVE_RUN missing: $marker" >&2; exit 1; }
  count=$(sed '/^[[:space:]]*$/d' "$marker" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || { echo "ACTIVE_RUN must contain exactly one task id" >&2; exit 1; }
  task=$(sed '/^[[:space:]]*$/d' "$marker")
  case "$task" in *[!A-Za-z0-9_-]*|'') echo "invalid active task id" >&2; exit 1;; esac
  [ -d "$(run_dir "$task")" ] || { echo "active run not found: $task" >&2; exit 1; }
  printf '%s\n' "$task"
}

effective() {
  task=${1:-$(active_run)}; run=$(run_dir "$task")/RUN.yaml
  mode=$( [ -f "$run" ] && sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1 || true )
  profile=$( [ -f "$run" ] && sed -n 's/^[[:space:]]*profile: *//p' "$run" | head -1 || true )
  [ -n "$mode" ] || mode=$(config_value default_mode "$config")
  [ -n "$profile" ] || profile=$(config_value default_profile "$config")
  policy=$root/.agents/modes/$mode.yaml
  [ -f "$policy" ] || { echo "invalid mode: $mode" >&2; exit 1; }
  printf 'mode=%s\nprofile=%s\ntask=%s\npolicy=%s\n' "$mode" "$profile" "$task" "${policy#$root/}"
  awk '
    /^[a-z_]+:$/ { section=substr($0,1,length($0)-1); next }
    /^[[:space:]]+[a-z_]+:/ {
      line=$0; sub(/^[[:space:]]+/, "", line); key=line; sub(/:.*/, "", key)
      value=line; sub(/^[^:]*:[[:space:]]*/, "", value)
      if (section ~ /^(wiki|memory|self_learning|orchestration|review|verification)$/ || key ~ /^(enabled|required|read|write|write_during_code_transaction|max_implementation_workers|max_bounded_fix_attempts|swarm|independent|independent_verifier)$/) print section "." key "=" value
    }
  ' "$policy"
}

replace_hashes() {
  dir=$1; target=$2; mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$dir/RUN.yaml" | head -1)
  [ -n "$mode" ] || mode=$(config_value default_mode "$config")
  task_hash=$(hash_file "$dir/TASK.md"); evidence_hash=$(hash_file "$dir/EVIDENCE.md"); plan_hash=$(hash_file "$dir/PLAN.md"); policy_hash=$(hash_file "$root/.agents/modes/$mode.yaml")
  awk -v a="$task_hash" -v b="$evidence_hash" -v c="$plan_hash" -v d="$policy_hash" '
    /^[[:space:]]*task_sha256:/ { print "  task_sha256: \"" a "\""; next }
    /^[[:space:]]*evidence_sha256:/ { print "  evidence_sha256: \"" b "\""; next }
    /^[[:space:]]*plan_sha256:/ { print "  plan_sha256: \"" c "\""; next }
    /^[[:space:]]*policy_sha256:/ { print "  policy_sha256: \"" d "\""; next }
    { print }
  ' "$dir/RUN.yaml" > "$target"
}

verify_freeze() {
  id=$1; dir=$(run_dir "$id"); run=$dir/RUN.yaml; [ -f "$run" ] || { echo "RUN.yaml missing" >&2; return 1; }
  mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1); [ -f "$root/.agents/modes/$mode.yaml" ] || { echo "mode policy missing" >&2; return 1; }
  for pair in "task TASK.md" "evidence EVIDENCE.md" "plan PLAN.md"; do
    set -- $pair; stored=$(sed -n "s/^[[:space:]]*$1_sha256: *[\"]*\([^\" ]*\).*/\1/p" "$run" | head -1); actual=$(hash_file "$dir/$2")
    [ -n "$stored" ] && [ "$stored" = "$actual" ] || { echo "freeze mismatch: $1" >&2; return 1; }
  done
  stored=$(sed -n 's/^[[:space:]]*policy_sha256: *[\"]*\([^\" ]*\).*/\1/p' "$run" | head -1); actual=$(hash_file "$root/.agents/modes/$mode.yaml")
  [ -n "$stored" ] && [ "$stored" = "$actual" ] || { echo "freeze mismatch: policy" >&2; return 1; }; echo "freeze verified: $id"
}

scope_mappings() {
  awk '
    /^scope:$/ { inside=1; next }
    inside && /^---$/ { exit }
    inside && /^  - path: / { path=$0; sub(/^  - path: /, "", path); next }
    inside && /^    criteria: \[/ { c=$0; sub(/^    criteria: \[/, "", c); sub(/\]$/, "", c); if (path == "" || c == "") bad=1; else print path "|" c; path="" }
    END { if (bad || path != "") exit 1 }
  ' "$1"
}
verify_scope() {
  id=$1; plan=$(run_dir "$id")/PLAN.md; mappings=$(scope_mappings "$plan") || { echo "invalid scope mapping" >&2; return 1; }; [ -n "$mappings" ] || { echo "scope mapping missing" >&2; return 1; }
  changes=$( { git -C "$root" diff --no-renames --name-only; git -C "$root" diff --cached --no-renames --name-only; git -C "$root" ls-files --others --exclude-standard; } | sort -u)
  unexpected=""; for changed in $changes; do printf '%s\n' "$mappings" | cut -d '|' -f1 | grep -Fxq "$changed" || unexpected="${unexpected}${changed}\n"; done
  [ -z "$unexpected" ] || { echo "unexpected or unmapped changed paths:" >&2; printf '%b' "$unexpected" >&2; return 1; }; echo "scope check passed: $id"
}

freeze() {
  id=$1; dir=$(run_dir "$id"); for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml; do [ -f "$dir/$f" ] || { echo "missing $f" >&2; exit 1; }; done
  if grep -q 'sha256: "[0-9a-f][0-9a-f]' "$dir/RUN.yaml"; then [ "${2:-}" = refreeze ] && [ -n "${3:-}" ] && [ -f "$dir/amendments/$3" ] || { echo "existing freeze requires explicit amendment" >&2; exit 1; }; fi
  tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"; mv "$tmp" "$dir/RUN.yaml"; echo "freeze recorded: $id"
}

fixture_test() {
  tmp=$(mktemp -d /tmp/deterministic-agent.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/FIX/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/docs/wiki"
  cp "$root/scripts/agent.sh" "$root/scripts/wiki-lint.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"; printf 'FIX\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task\n' > "$tmp/.agents/runs/FIX/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/FIX/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '  - path: .agents/runs/FIX/RUN.yaml' '    criteria: [AC-1]' '  - path: .agents/runs/FIX/amendments/001.md' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/FIX/PLAN.md"
  printf '%s\n' 'execution:' '  mode: deterministic' '  profile: core' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' > "$tmp/.agents/runs/FIX/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/FIX/review/code-review.md"; printf '# verifier\n' > "$tmp/.agents/runs/FIX/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/FIX/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email fixture@example.invalid; git config user.name fixture; : > authorized.txt; git add -- .agents scripts docs authorized.txt; git commit -qm baseline
    ./scripts/agent.sh freeze FIX; ./scripts/agent.sh verify-freeze FIX; cp .agents/runs/FIX/EVIDENCE.md evidence.original; printf 'tamper\n' >> .agents/runs/FIX/EVIDENCE.md
    if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; mv evidence.original .agents/runs/FIX/EVIDENCE.md; mkdir -p .agents/runs/FIX/amendments; printf '# amendment\n' > .agents/runs/FIX/amendments/001.md; ./scripts/agent.sh refreeze FIX 001.md
    printf 'change\n' > authorized.txt; ./scripts/agent.sh verify-scope FIX; printf 'unexpected\n' > unexpected.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; rm unexpected.txt
    printf 'MISSING\n' > .agents/ACTIVE_RUN; if ./scripts/agent.sh status; then exit 1; fi; printf 'FIX\n' > .agents/ACTIVE_RUN; printf '# index\n[[missing]]\n' > docs/wiki/index.md; if ./scripts/wiki-lint.sh; then exit 1; fi)
  echo 'agent control tests passed'
}

command=${1:-}; case "$command" in
  status) id=$(active_run); echo "active_task=$id"; effective "$id" ;;
  effective) effective "${2:-}" ;;
  freeze) freeze "${2:?usage: $0 freeze <TASK-ID>}" ;;
  refreeze) freeze "${2:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" refreeze "${3:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze <TASK-ID>}" ;;
  verify-scope) verify_scope "${2:?usage: $0 verify-scope <TASK-ID>}" ;;
  validate) id=${2:?usage: $0 validate <TASK-ID>}; for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml review/code-review.md review/verification.md RESULT.md; do [ -f "$(run_dir "$id")/$f" ] || { echo "missing required artifact: $f" >&2; exit 1; }; done; scope_mappings "$(run_dir "$id")/PLAN.md" >/dev/null; verify_freeze "$id"; echo "run validated: $id" ;;
  test) fixture_test ;;
  *) echo "usage: $0 {status|effective|freeze|refreeze|verify-freeze|verify-scope|validate|test} [TASK-ID]" >&2; exit 2 ;;
esac


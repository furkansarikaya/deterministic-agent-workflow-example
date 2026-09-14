#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml

value() { sed -n "s/^$1: *//p" "$2" | head -n 1 | tr -d '"'; }
active_run() {
  marker=$root/$(value active_run_file "$config")
  [ -f "$marker" ] || { echo "ACTIVE_RUN missing: $marker" >&2; exit 1; }
  count=$(sed '/^[[:space:]]*$/d' "$marker" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || { echo "ACTIVE_RUN must contain exactly one task id" >&2; exit 1; }
  task=$(sed '/^[[:space:]]*$/d' "$marker")
  case "$task" in *[!A-Za-z0-9_-]*|'') echo "invalid active task id" >&2; exit 1;; esac
  [ -d "$root/.agents/runs/$task" ] || { echo "active run not found: $task" >&2; exit 1; }
  printf '%s\n' "$task"
}

[ "${1:-}" = effective ] || { echo "usage: $0 effective [TASK-ID]" >&2; exit 2; }
task=${2:-$(active_run)}
run=$root/.agents/runs/$task/RUN.yaml
mode=$( [ -f "$run" ] && sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1 || true )
profile=$( [ -f "$run" ] && sed -n 's/^[[:space:]]*profile: *//p' "$run" | head -1 || true )
[ -n "$mode" ] || mode=$(value default_mode "$config")
[ -n "$profile" ] || profile=$(value default_profile "$config")
policy=$root/.agents/modes/$mode.yaml
[ -f "$policy" ] || { echo "invalid mode: $mode" >&2; exit 1; }

printf 'mode=%s\nprofile=%s\ntask=%s\npolicy=%s\n' "$mode" "$profile" "$task" "${policy#$root/}"
awk '
  /^[a-z_]+:$/ { section=substr($0,1,length($0)-1); next }
  /^[[:space:]]+[a-z_]+:/ {
    line=$0; sub(/^[[:space:]]+/, "", line)
    key=line; sub(/:.*/, "", key)
    value=line; sub(/^[^:]*:[[:space:]]*/, "", value)
    if (section ~ /^(wiki|memory|self_learning|orchestration|review|verification)$/ || key ~ /^(enabled|required|read|write|write_during_code_transaction|max_implementation_workers|max_bounded_fix_attempts|swarm|independent|independent_verifier)$/) print section "." key "=" value
  }
' "$policy"


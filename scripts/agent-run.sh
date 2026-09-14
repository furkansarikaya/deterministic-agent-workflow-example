#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
run_dir() { printf '%s/.agents/runs/%s\n' "$root" "$1"; }
active() {
  marker=$root/$(sed -n 's/^active_run_file: *//p' "$config" | head -1)
  [ -f "$marker" ] || { echo "ACTIVE_RUN missing" >&2; exit 1; }
  count=$(sed '/^[[:space:]]*$/d' "$marker" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || { echo "ACTIVE_RUN must contain exactly one task id" >&2; exit 1; }
  id=$(sed '/^[[:space:]]*$/d' "$marker")
  case "$id" in *[!A-Za-z0-9_-]*|'') echo "invalid active task id" >&2; exit 1;; esac
  [ -d "$(run_dir "$id")" ] || { echo "active run not found: $id" >&2; exit 1; }
  printf '%s\n' "$id"
}
replace_hashes() {
  source=$1; target=$2
  task_hash=$(hash_file "$source/TASK.md")
  evidence_hash=$(hash_file "$source/EVIDENCE.md")
  plan_hash=$(hash_file "$source/PLAN.md")
  mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$source/RUN.yaml" | head -1)
  [ -n "$mode" ] || mode=$(sed -n 's/^default_mode: *//p' "$config" | head -1)
  policy_hash=$(hash_file "$root/.agents/modes/$mode.yaml")
  awk -v a="$task_hash" -v b="$evidence_hash" -v c="$plan_hash" -v d="$policy_hash" '
    /^[[:space:]]*task_sha256:/ { print "  task_sha256: \"" a "\""; next }
    /^[[:space:]]*evidence_sha256:/ { print "  evidence_sha256: \"" b "\""; next }
    /^[[:space:]]*plan_sha256:/ { print "  plan_sha256: \"" c "\""; next }
    /^[[:space:]]*policy_sha256:/ { print "  policy_sha256: \"" d "\""; next }
    { print }
  ' "$source/RUN.yaml" > "$target"
}
verify_freeze() {
  id=$1; dir=$(run_dir "$id"); run=$dir/RUN.yaml
  [ -f "$run" ] || { echo "RUN.yaml missing" >&2; return 1; }
  mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1)
  [ -f "$root/.agents/modes/$mode.yaml" ] || { echo "mode policy missing" >&2; return 1; }
  for pair in "task TASK.md" "evidence EVIDENCE.md" "plan PLAN.md"; do
    set -- $pair; stored=$(sed -n "s/^[[:space:]]*$1_sha256: *[\"]*\([^\" ]*\).*/\1/p" "$run" | head -1)
    actual=$(hash_file "$dir/$2")
    [ -n "$stored" ] && [ "$stored" = "$actual" ] || { echo "freeze mismatch: $1" >&2; return 1; }
  done
  stored=$(sed -n 's/^[[:space:]]*policy_sha256: *[\"]*\([^\" ]*\).*/\1/p' "$run" | head -1)
  actual=$(hash_file "$root/.agents/modes/$mode.yaml")
  [ -n "$stored" ] && [ "$stored" = "$actual" ] || { echo "freeze mismatch: policy" >&2; return 1; }
  echo "freeze verified: $id"
}
command=${1:-}
case "$command" in
  status) id=$(active); echo "active_task=$id"; "$root/scripts/agent-policy.sh" effective "$id" ;;
  freeze|refreeze)
    id=${2:?usage: $0 freeze '<TASK-ID>'}; dir=$(run_dir "$id")
    for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml; do [ -f "$dir/$f" ] || { echo "missing $f" >&2; exit 1; }; done
    if grep -q 'sha256: "[0-9a-f][0-9a-f]' "$dir/RUN.yaml"; then
      [ "$command" = refreeze ] && [ -n "${3:-}" ] && [ -f "$dir/amendments/$3" ] || { echo "existing freeze requires explicit amendment" >&2; exit 1; }
    fi
    tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"; mv "$tmp" "$dir/RUN.yaml"; echo "freeze recorded: $id" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze '<TASK-ID>'}" ;;
  validate)
    id=${2:?usage: $0 validate '<TASK-ID>'}; dir=$(run_dir "$id")
    for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml review/code-review.md review/verification.md RESULT.md; do [ -f "$dir/$f" ] || { echo "missing required artifact: $f" >&2; exit 1; }; done
    "$root/scripts/check-scope.sh" --validate-plan "$id"; verify_freeze "$id"; echo "run validated: $id" ;;
  *) echo "usage: $0 {status|freeze|refreeze|verify-freeze|validate} [TASK-ID]" >&2; exit 2 ;;
esac

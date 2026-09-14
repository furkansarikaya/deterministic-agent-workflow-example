#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
run_dir() { printf '%s/.agents/runs/%s\n' "$root" "$1"; }
config_value() { sed -n "s/^$1: *//p" "$2" | head -n 1 | tr -d '"'; }
fail() { echo "$*" >&2; return 1; }

valid_task_id() { case "$1" in *[!A-Za-z0-9_-]*|'') return 1;; esac; }

# Empty is the intentional checked-in template state. Missing or malformed is not.
active_run() {
  marker=$root/$(config_value active_run_file "$config")
  [ -f "$marker" ] || fail "ACTIVE_RUN missing: $marker"
  count=$(sed '/^[[:space:]]*$/d' "$marker" | wc -l | tr -d ' ')
  [ "$count" = 0 ] && return 0
  [ "$count" = 1 ] || fail "ACTIVE_RUN must contain at most one task id"
  task=$(sed '/^[[:space:]]*$/d' "$marker")
  valid_task_id "$task" || fail "invalid active task id"
  [ -d "$(run_dir "$task")" ] || fail "active run not found: $task"
  printf '%s\n' "$task"
}
require_run() { valid_task_id "$1" || fail "invalid task id"; [ -d "$(run_dir "$1")" ] || fail "run not found: $1"; }

effective() {
  task=${1:-}; [ -n "$task" ] || task=$(active_run); [ -z "$task" ] || require_run "$task"
  run=$( [ -n "$task" ] && printf '%s/RUN.yaml' "$(run_dir "$task")" || true )
  mode=$( [ -n "$run" ] && [ -f "$run" ] && sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1 || true )
  profile=$( [ -n "$run" ] && [ -f "$run" ] && sed -n 's/^[[:space:]]*profile: *//p' "$run" | head -1 || true )
  [ -n "$mode" ] || mode=$(config_value default_mode "$config"); [ -n "$profile" ] || profile=$(config_value default_profile "$config")
  policy=$root/.agents/modes/$mode.yaml; [ -f "$policy" ] || fail "invalid mode: $mode"
  printf 'mode=%s\nprofile=%s\ntask=%s\nimplementation_allowed=%s\npolicy=%s\n' "$mode" "$profile" "${task:-none}" "$( [ -n "$task" ] && echo true || echo false )" "${policy#$root/}"
  awk '
    /^[a-z_]+:$/ { section=substr($0,1,length($0)-1); next }
    /^[[:space:]]+[a-z_]+:/ {
      line=$0; sub(/^[[:space:]]+/, "", line); key=line; sub(/:.*/, "", key)
      value=line; sub(/^[^:]*:[[:space:]]*/, "", value)
      if (value != "" && (section ~ /^(task|baseline|evidence|plan|context|wiki|memory|self_learning|orchestration|review|verification)$/ || key ~ /^(enabled|required|read|write|write_during_code_transaction|max_implementation_workers|max_bounded_fix_attempts|swarm|independent|independent_verifier|required_before_implementation|strategy|control_plane|default|index_first|expand_only_if_needed|load_unrelated_runs|include_session_history_in_review)$/)) print section "." key "=" value
    }
  ' "$policy"
}

run_state() { sed -n 's/^[[:space:]]*state: *//p' "$1/RUN.yaml" | head -1; }
baseline_status() { awk '/^baseline:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*status:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$1/RUN.yaml"; }
repository_base_sha() { awk '/^repository:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*base_sha:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$1/RUN.yaml"; }
historical_reference() { [ "$1" = EXAMPLE-001 ] && [ "$(baseline_status "$(run_dir "$1")")" = legacy_not_captured ] && [ "$(run_state "$(run_dir "$1")")" = CODE_DONE ]; }

# Only regular files are fingerprinted. Symlinks and special files are refused rather
# than followed, so a baseline never reads outside the working tree unexpectedly.
fingerprint_path() {
  path=$1 target=$root/$path
  [ ! -L "$target" ] || fail "cannot baseline symlink: $path"
  if [ -f "$target" ]; then hash_file "$target"; return 0; fi
  [ ! -e "$target" ] && { printf '%s\n' missing; return 0; }
  fail "cannot baseline non-regular file: $path"
}
current_tracked_paths() { { git -C "$root" diff --no-renames --name-only; git -C "$root" diff --cached --no-renames --name-only; } | sort -u; }
current_untracked_paths() { git -C "$root" ls-files --others --exclude-standard | sort -u; }

baseline_entries() {
  awk '
    /^baseline:$/ { inside=1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && /^  (tracked|untracked):$/ { type=$1; sub(/:$/, "", type); next }
    inside && /^    - path: / { path=$0; sub(/^    - path: /, "", path); if (getline <= 0 || $0 !~ /^      sha256: /) exit 1; hash=$0; sub(/^      sha256: /, "", hash); gsub(/"/, "", hash); print type "|" path "|" hash }
  ' "$1/RUN.yaml"
}
baseline_fingerprint() {
  type=$1 path=$2 dir=$3
  (baseline_entries "$dir" | while IFS='|' read -r entry_type entry_path entry_hash; do [ "$entry_type" = "$type" ] && [ "$entry_path" = "$path" ] && { printf '%s\n' "$entry_hash"; break; }; done) || true
}
remove_pending_baseline() { awk '/^baseline:$/ { inside=1; next } inside && /^[^[:space:]]/ { inside=0 } !inside { print }' "$1" > "$2"; }
replace_repository_base_sha() {
  awk -v sha="$2" '
    /^repository:$/ { inside=1; print; next }
    inside && /^[^[:space:]]/ { inside=0 }
    inside && /^[[:space:]]*base_sha:/ { print "  base_sha: \"" sha "\""; found=1; next }
    { print }
    END { if (!found) exit 1 }
  ' "$1" > "$3"
}

baseline() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "cannot record a baseline for CODE_DONE run: $id"
  status=$(baseline_status "$dir"); case "$status" in ''|pending) ;; *) fail "baseline already exists for $id; refusing to overwrite";; esac
  tmp=$dir/RUN.yaml.tmp; remove_pending_baseline "$dir/RUN.yaml" "$tmp"
  base_sha=$(git -C "$root" rev-parse HEAD)
  replace_repository_base_sha "$tmp" "$base_sha" "$tmp.base" || { rm -f "$tmp" "$tmp.base"; fail "RUN.yaml requires repository.base_sha"; }
  mv "$tmp.base" "$tmp"
  {
    printf '\nbaseline:\n  status: captured\n  tracked:\n'
    current_tracked_paths | while IFS= read -r path; do [ -n "$path" ] || continue; printf '    - path: %s\n      sha256: "%s"\n' "$path" "$(fingerprint_path "$path")"; done
    printf '  untracked:\n'
    current_untracked_paths | while IFS= read -r path; do [ -n "$path" ] || continue; printf '    - path: %s\n      sha256: "%s"\n' "$path" "$(fingerprint_path "$path")"; done
  } >> "$tmp"
  mv "$tmp" "$dir/RUN.yaml"; echo "baseline recorded: $id"
}

replace_hashes() {
  dir=$1 target=$2; mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$dir/RUN.yaml" | head -1); [ -n "$mode" ] || mode=$(config_value default_mode "$config")
  task_hash=$(hash_file "$dir/TASK.md"); evidence_hash=$(hash_file "$dir/EVIDENCE.md"); plan_hash=$(hash_file "$dir/PLAN.md"); policy_hash=$(hash_file "$root/.agents/modes/$mode.yaml")
  awk -v a="$task_hash" -v b="$evidence_hash" -v c="$plan_hash" -v d="$policy_hash" '
    /^[[:space:]]*task_sha256:/ { print "  task_sha256: \"" a "\""; next }
    /^[[:space:]]*evidence_sha256:/ { print "  evidence_sha256: \"" b "\""; next }
    /^[[:space:]]*plan_sha256:/ { print "  plan_sha256: \"" c "\""; next }
    /^[[:space:]]*policy_sha256:/ { print "  policy_sha256: \"" d "\""; next }
    { print }
  ' "$dir/RUN.yaml" > "$target"
}
freeze_hash_present() {
  awk '/^freeze:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*(task|evidence|plan|policy)_sha256: "[0-9a-f][0-9a-f]/ { found=1 } END { exit !found }' "$1/RUN.yaml"
}
verify_freeze() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); run=$dir/RUN.yaml; [ -f "$run" ] || fail "RUN.yaml missing"
  mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$run" | head -1); [ -f "$root/.agents/modes/$mode.yaml" ] || fail "mode policy missing"
  for pair in "task TASK.md" "evidence EVIDENCE.md" "plan PLAN.md"; do set -- $pair; stored=$(sed -n "s/^[[:space:]]*$1_sha256: *[\"]*\([^\" ]*\).*/\1/p" "$run" | head -1); actual=$(hash_file "$dir/$2"); [ -n "$stored" ] && [ "$stored" = "$actual" ] || fail "freeze mismatch: $1"; done
  stored=$(sed -n 's/^[[:space:]]*policy_sha256: *[\"]*\([^\" ]*\).*/\1/p' "$run" | head -1); actual=$(hash_file "$root/.agents/modes/$mode.yaml")
  if [ -z "$stored" ] || [ "$stored" != "$actual" ]; then
    historical_reference "$id" || fail "freeze mismatch: policy"
    echo "historical policy hash retained for reference: $id"
  fi
  echo "freeze verified: $id"
}
scope_mappings() {
  awk '
    /^scope:$/ { inside=1; next } inside && /^---$/ { exit }
    inside && /^  - path: / { path=$0; sub(/^  - path: /, "", path); next }
    inside && /^    criteria: \[/ { c=$0; sub(/^    criteria: \[/, "", c); sub(/\]$/, "", c); if (path == "" || c == "") bad=1; else print path "|" c; path="" }
    END { if (bad || path != "") exit 1 }
  ' "$1"
}
authorized_path() { printf '%s\n' "$1" | cut -d '|' -f1 | grep -Fxq "$2"; }

# Run metadata is deliberately separate from application scope. This exact allowlist
# applies only to the active run directory; no other .agents paths are ignored.
known_control_artifact() {
  id=$1 path=$2
  case "$path" in
    ".agents/runs/$id/TASK.md"|".agents/runs/$id/EVIDENCE.md"|".agents/runs/$id/PLAN.md"|".agents/runs/$id/RUN.yaml"|".agents/runs/$id/RESULT.md"|".agents/runs/$id/review/code-review.md"|".agents/runs/$id/review/verification.md"|".agents/runs/$id/amendments/"*) return 0 ;;
    *) return 1 ;;
  esac
}
validate_control_artifacts() {
  id=$1 dir=$(run_dir "$id") bad=''
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    path=${file#$root/}; known_control_artifact "$id" "$path" || bad="${bad}${path}\n"
  done <<EOF
$(find "$dir" -type f -print)
EOF
  while IFS= read -r file; do [ -n "$file" ] || continue; bad="${bad}${file#$root/}\n"; done <<EOF
$(find "$dir" -type l -print)
EOF
  [ -z "$bad" ] || { echo "unexpected run artifact:" >&2; printf '%b' "$bad" >&2; return 1; }
}
validate_captured_baseline() {
  dir=$1 sha=$(repository_base_sha "$dir")
  case "$sha" in ''|PENDING|*'<'*|*[!0-9a-f]*) fail "invalid repository.base_sha";; esac
  git -C "$root" rev-parse --verify "${sha}^{commit}" >/dev/null 2>&1 || fail "repository.base_sha is not a known commit"
  awk '
    /^baseline:$/ { inside=1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && /^  status: captured$/ { status=1; next }
    inside && /^  (tracked|untracked):$/ { type=$1; sub(/:$/, "", type); sections[type]=1; next }
    inside && /^    - path: / {
      path=$0; sub(/^    - path: /, "", path)
      if (path == "" || type == "" || getline <= 0 || $0 !~ /^      sha256: /) bad=1
      else { value=$0; sub(/^      sha256: /, "", value); gsub(/"/, "", value); if (!((length(value) == 64 && value ~ /^[0-9a-f]+$/) || (type == "tracked" && value == "missing"))) bad=1 }
    }
    END { if (!status || !sections["tracked"] || !sections["untracked"] || bad) exit 1 }
  ' "$dir/RUN.yaml" || fail "invalid captured baseline entries"
}

verify_scope() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); mappings=$(scope_mappings "$dir/PLAN.md") || fail "invalid scope mapping"; [ -n "$mappings" ] || fail "scope mapping missing"
  status=$(baseline_status "$dir"); [ "$status" = captured ] || { historical_reference "$id" && fail "scope verification unavailable for historical reference: $id"; fail "baseline required before scope verification: $id"; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-scope.XXXXXX")
  for type in tracked untracked; do
    paths=$( [ "$type" = tracked ] && current_tracked_paths || current_untracked_paths )
    printf '%s\n' "$paths" | while IFS= read -r changed; do
      [ -n "$changed" ] || continue; prior=$(baseline_fingerprint "$type" "$changed" "$dir"); current=$(fingerprint_path "$changed")
      known_control_artifact "$id" "$changed" && continue
      if [ -n "$prior" ] && [ "$prior" = "$current" ]; then continue; fi
      authorized_path "$mappings" "$changed" || printf '%s\n' "$changed" >> "$tmp"
    done
  done
  unexpected=$(cat "$tmp"); rm "$tmp"
  [ -z "$unexpected" ] || { echo "unexpected or unmapped task-introduced paths:" >&2; printf '%s\n' "$unexpected" >&2; return 1; }; echo "scope check passed: $id"
}

freeze() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml; do [ -f "$dir/$f" ] || fail "missing $f"; done
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "cannot freeze completed run: $id"; [ "$(baseline_status "$dir")" = captured ] || fail "baseline required before freeze: $id"
  if freeze_hash_present "$dir"; then [ "${2:-}" = refreeze ] && [ -n "${3:-}" ] && [ -f "$dir/amendments/$3" ] || fail "existing freeze requires explicit amendment"; fi
  tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"; mv "$tmp" "$dir/RUN.yaml"; echo "freeze recorded: $id"
}

fixture_test() {
  tmp=$(mktemp -d /tmp/deterministic-agent.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/FIX/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/docs/wiki"
  cp "$root/scripts/agent.sh" "$root/scripts/wiki-lint.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"; printf 'FIX\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task\n' > "$tmp/.agents/runs/FIX/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/FIX/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/FIX/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'execution:' '  mode: deterministic' '  profile: core' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' > "$tmp/.agents/runs/FIX/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/FIX/review/code-review.md"; printf '# verifier\n' > "$tmp/.agents/runs/FIX/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/FIX/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email fixture@example.invalid; git config user.name fixture; : > authorized.txt; : > user-dirty.txt; git add -- .agents scripts docs authorized.txt user-dirty.txt; git commit -qm baseline
    printf 'user work\n' > user-dirty.txt; : > user-untracked.txt; ./scripts/agent.sh baseline FIX; printf 'discovered\n' >> .agents/runs/FIX/EVIDENCE.md; printf 'planned\n' >> .agents/runs/FIX/PLAN.md; ./scripts/agent.sh verify-scope FIX; ./scripts/agent.sh freeze FIX; ./scripts/agent.sh verify-freeze FIX; ./scripts/agent.sh validate FIX; cp .agents/runs/FIX/RUN.yaml run.original; sed 's/base_sha: ".*"/base_sha: "PENDING"/' run.original > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh validate FIX; then exit 1; fi; mv run.original .agents/runs/FIX/RUN.yaml
    ./scripts/agent.sh verify-scope FIX
    printf 'agent touched dirty path\n' >> user-dirty.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; git checkout -- user-dirty.txt; printf 'user work\n' > user-dirty.txt
    printf 'agent touched untracked path\n' >> user-untracked.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; : > user-untracked.txt
    printf 'change\n' > authorized.txt; ./scripts/agent.sh verify-scope FIX; printf 'unexpected\n' > unexpected.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; rm unexpected.txt
    printf 'random\n' > .agents/runs/FIX/random.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; if ./scripts/agent.sh validate FIX; then exit 1; fi; rm .agents/runs/FIX/random.txt
    cp .agents/runs/FIX/EVIDENCE.md evidence.original; printf 'tamper\n' >> .agents/runs/FIX/EVIDENCE.md; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; mv evidence.original .agents/runs/FIX/EVIDENCE.md; mkdir -p .agents/runs/FIX/amendments; printf '# amendment\n' > .agents/runs/FIX/amendments/001.md; ./scripts/agent.sh refreeze FIX 001.md
    printf 'MISSING\n' > .agents/ACTIVE_RUN; if ./scripts/agent.sh status; then exit 1; fi; : > .agents/ACTIVE_RUN; ./scripts/agent.sh status | grep -Fxq 'active_task=none'; printf 'FIX\n' > .agents/ACTIVE_RUN
    printf '# index\n[[missing]]\n' > docs/wiki/index.md; if ./scripts/wiki-lint.sh; then exit 1; fi)
  echo 'agent control tests passed'
}

command=${1:-}; case "$command" in
  status) id=$(active_run); echo "active_task=${id:-none}"; echo "implementation_allowed=$( [ -n "$id" ] && echo true || echo false )"; effective "$id" ;;
  effective) effective "${2:-}" ;;
  baseline) baseline "${2:?usage: $0 baseline <TASK-ID>}" ;;
  freeze) freeze "${2:?usage: $0 freeze <TASK-ID>}" ;;
  refreeze) freeze "${2:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" refreeze "${3:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze <TASK-ID>}" ;;
  verify-scope) verify_scope "${2:?usage: $0 verify-scope <TASK-ID>}" ;;
  validate) id=${2:?usage: $0 validate <TASK-ID>}; require_run "$id"; dir=$(run_dir "$id"); for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml review/code-review.md review/verification.md RESULT.md; do [ -f "$dir/$f" ] || fail "missing required artifact: $f"; done; validate_control_artifacts "$id"; scope_mappings "$dir/PLAN.md" >/dev/null; status=$(baseline_status "$dir"); if [ "$status" = captured ]; then validate_captured_baseline "$dir"; else historical_reference "$id" || fail "baseline missing or pending: $id"; fi; verify_freeze "$id"; echo "run validated: $id" ;;
  test) fixture_test ;;
  *) echo "usage: $0 {status|effective|baseline|freeze|refreeze|verify-freeze|verify-scope|validate|test} [TASK-ID]" >&2; exit 2 ;;
esac

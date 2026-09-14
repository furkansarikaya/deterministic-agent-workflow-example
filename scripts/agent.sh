#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml
execution_role=${AGENT_ROLE:-full_lifecycle}
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
run_dir() { printf '%s/.agents/runs/%s\n' "$root" "$1"; }
config_value() { sed -n "s/^$1: *//p" "$2" | head -n 1 | tr -d '"'; }
fail() { echo "$*" >&2; return 1; }
valid_role() { case "$execution_role" in full_lifecycle|implementation_worker) ;; *) fail "invalid execution role: $execution_role";; esac; }
require_full_lifecycle() { [ "$execution_role" = full_lifecycle ] || fail "command denied for implementation_worker"; }

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

run_state() { sed -n 's/^[[:space:]]*state: *//p' "$1/RUN.yaml" | head -1 | tr -d '"'; }
baseline_status() { awk '/^baseline:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*status:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$1/RUN.yaml"; }
repository_base_sha() { awk '/^repository:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*base_sha:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$1/RUN.yaml"; }
section_value() { awk -v section="$2" -v key="$3" '$0 == section ":" { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && $0 ~ "^[[:space:]]*" key ":" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$1/RUN.yaml"; }
replace_section_value() {
  awk -v section="$2" -v key="$3" -v value="$4" '
    $0 == section ":" { inside=1; print; next }
    inside && /^[^[:space:]]/ { inside=0 }
    inside && $0 ~ "^[[:space:]]*" key ":" { print "  " key ": \"" value "\""; found=1; next }
    { print }
    END { if (!found) exit 1 }
  ' "$1/RUN.yaml" > "$5"
}
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
set_task_source_revision() {
  dir=$1 type=$(section_value "$dir" task_source type)
  case "$type" in
    local_markdown) source=$(local_task_source "$dir") || return 1; replace_section_value "$dir" task_source revision "$(hash_file "$source")" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    none) [ "$(section_value "$dir" task_source revision)" = not_applicable ] || fail "task source none requires revision: not_applicable" ;;
    *) fail "task source adapter unavailable: ${type:-missing}" ;;
  esac
}
local_task_source() {
  dir=$1 path=$(section_value "$dir" task_source path)
  case "$path" in ''|/*|*'..'*|*'//'*) fail "invalid local Markdown task source path";; esac
  source=$root/$path
  [ ! -L "$source" ] || fail "task source must not be a symlink: $path"
  [ -f "$source" ] || fail "task source missing or non-regular: $path"
  printf '%s\n' "$source"
}
verify_freshness() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  historical_reference "$id" && { echo "freshness historical reference: $id"; return 0; }
  verify_freeze "$id"
  base=$(repository_base_sha "$dir"); head=$(git -C "$root" rev-parse HEAD)
  [ "$base" = "$head" ] || fail "stale plan: repository.base_sha changed ($base -> $head); amendment and refreeze required"
  type=$(section_value "$dir" task_source type); revision=$(section_value "$dir" task_source revision)
  case "$type:$revision" in
    local_markdown:*) source=$(local_task_source "$dir") || return 1; [ "$revision" = "$(hash_file "$source")" ] || fail "stale plan: task source revision changed; amendment and refreeze required" ;;
    none:not_applicable) : ;;
    *) fail "task source revision unavailable or unsupported; amendment or adapter required" ;;
  esac
  echo "planning freshness verified: $id"
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
task_owned_paths() {
  id=$1; dir=$(run_dir "$id"); mappings=$(scope_mappings "$dir/PLAN.md") || return 1
  for type in tracked untracked; do
    paths=$( [ "$type" = tracked ] && current_tracked_paths || current_untracked_paths )
    printf '%s\n' "$paths" | while IFS= read -r changed; do
      [ -n "$changed" ] || continue; known_control_artifact "$id" "$changed" && continue
      prior=$(baseline_fingerprint "$type" "$changed" "$dir"); current=$(fingerprint_path "$changed")
      [ -n "$prior" ] && [ "$prior" = "$current" ] && continue
      authorized_path "$mappings" "$changed" || continue
      printf '%s\n' "$changed"
    done
  done | sort -u
}
task_patch_fingerprint() {
  id=$1; task_owned_paths "$id" | while IFS= read -r path; do [ -n "$path" ] && printf '%s %s\n' "$path" "$(fingerprint_path "$path")"; done | shasum -a 256 | awk '{print $1}'
}
record_handoff() {
  id=$1 phase=$2; require_run "$id"; dir=$(run_dir "$id")
  verify_freshness "$id"; verify_scope "$id"
  case "$phase" in IMPLEMENTING|VERIFIED|REVIEWED|CODE_DONE) ;; *) fail "invalid handoff phase";; esac
  patch=$(task_patch_fingerprint "$id")
  current=$(section_value "$dir" handoff state)
  case "$phase" in
    IMPLEMENTING)
      case "$current" in PLANNED|IMPLEMENTING) ;; *) fail "illegal handoff transition: $current -> $phase";; esac ;;
    VERIFIED)
      case "$current" in
        IMPLEMENTING|VERIFIED) ;;
        REVIEWED) [ "$(section_value "$dir" handoff verification_patch_sha256)" != "$patch" ] || fail "illegal handoff transition: $current -> $phase" ;;
        *) fail "illegal handoff transition: $current -> $phase" ;;
      esac
      replace_section_value "$dir" handoff verification_patch_sha256 "$patch" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
      replace_section_value "$dir" handoff review_patch_sha256 PENDING "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
      replace_section_value "$dir" handoff code_done_patch_sha256 PENDING "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    REVIEWED)
      case "$current" in VERIFIED|REVIEWED) ;; *) fail "illegal handoff transition: $current -> $phase";; esac
      [ "$(section_value "$dir" handoff verification_patch_sha256)" = "$patch" ] || fail "review blocked: verification stale or missing"
      replace_section_value "$dir" handoff review_patch_sha256 "$patch" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
      replace_section_value "$dir" handoff code_done_patch_sha256 PENDING "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    CODE_DONE)
      case "$current" in REVIEWED|CODE_DONE) ;; *) fail "illegal handoff transition: $current -> $phase";; esac
      [ "$(section_value "$dir" handoff verification_patch_sha256)" = "$patch" ] || fail "CODE_DONE blocked: verification stale or missing"
      [ "$(section_value "$dir" handoff review_patch_sha256)" = "$patch" ] || fail "CODE_DONE blocked: review stale or missing"
      replace_section_value "$dir" handoff code_done_patch_sha256 "$patch" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
  esac
  tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" handoff state "$phase" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  if [ "$phase" = CODE_DONE ]; then replace_section_value "$dir" execution state CODE_DONE "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"; fi
  echo "handoff recorded: $id $phase"
}
verify_handoff() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); historical_reference "$id" && { echo "handoff historical reference: $id"; return 0; }
  verify_scope "$id"; patch=$(task_patch_fingerprint "$id"); state=$(section_value "$dir" handoff state)
  for gate in verification review code_done; do
    recorded=$(section_value "$dir" handoff "${gate}_patch_sha256")
    case "$recorded" in ''|PENDING) continue;; esac
    [ "$recorded" = "$patch" ] || fail "${gate} stale: task-owned patch changed; rerun affected gate"
  done
  [ -n "$state" ] || fail "handoff state missing"
  echo "handoff integrity verified: $id"
}
delivery_check() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); historical_reference "$id" && fail "delivery unavailable for historical reference"
  [ "$(run_state "$dir")" = CODE_DONE ] || fail "delivery blocked: CODE_DONE required"
  branch=$(git -C "$root" branch --show-current); [ -n "$branch" ] || fail "delivery blocked: detached HEAD"
  verify_freshness "$id"; verify_scope "$id"; verify_handoff "$id"
  patch=$(task_patch_fingerprint "$id"); [ "$(section_value "$dir" handoff verification_patch_sha256)" = "$patch" ] || fail "delivery blocked: verification stale or missing"
  [ "$(section_value "$dir" handoff review_patch_sha256)" = "$patch" ] || fail "delivery blocked: review stale or missing"
  [ "$(section_value "$dir" handoff code_done_patch_sha256)" = "$patch" ] || fail "delivery blocked: CODE_DONE handoff stale or missing"
  printf 'delivery_branch=%s\ndelivery_ready=true\n' "$branch"
}

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
  set_task_source_revision "$dir"; tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"; mv "$tmp" "$dir/RUN.yaml"; echo "freeze recorded: $id"
}

fixture_test() {
  tmp=$(mktemp -d /tmp/deterministic-agent.XXXXXX); scratch=$(mktemp -d /tmp/deterministic-agent-scratch.XXXXXX); trap 'rm -rf "$tmp" "$scratch"' EXIT
  mkdir -p "$tmp/.agents/runs/FIX/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/docs/wiki" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$root/scripts/wiki-lint.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"; printf 'FIX\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task\n' > "$tmp/.agents/runs/FIX/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/FIX/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/FIX/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/FIX.md' '  revision: PENDING' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/FIX/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/FIX/review/code-review.md"; printf '# verifier\n' > "$tmp/.agents/runs/FIX/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/FIX/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email fixture@example.invalid; git config user.name fixture; : > authorized.txt; : > user-dirty.txt; printf '# canonical task\n' > tasks/FIX.md; git add -- .agents scripts docs tasks authorized.txt user-dirty.txt; git commit -qm baseline
    printf 'user work\n' > user-dirty.txt; : > user-untracked.txt; ./scripts/agent.sh baseline FIX; printf 'discovered\n' >> .agents/runs/FIX/EVIDENCE.md; printf 'planned\n' >> .agents/runs/FIX/PLAN.md; ./scripts/agent.sh verify-scope FIX; ./scripts/agent.sh freeze FIX; ./scripts/agent.sh verify-freeze FIX; ./scripts/agent.sh freshness FIX; if ./scripts/agent.sh handoff FIX VERIFIED; then exit 1; fi; cp tasks/FIX.md "$scratch/task-source.original"; printf 'changed source\n' >> tasks/FIX.md; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/task-source.original" tasks/FIX.md; mv tasks/FIX.md "$scratch/task-source.missing"; if ./scripts/agent.sh freshness FIX; then exit 1; fi; mv "$scratch/task-source.missing" tasks/FIX.md; cp .agents/runs/FIX/RUN.yaml "$scratch/source-run.original"; sed 's#path: tasks/FIX.md#path: ../outside.md#' "$scratch/source-run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/source-run.original" .agents/runs/FIX/RUN.yaml; cp .agents/runs/FIX/TASK.md "$scratch/task-contract.original"; printf 'changed contract\n' >> .agents/runs/FIX/TASK.md; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; cp "$scratch/task-contract.original" .agents/runs/FIX/TASK.md; ./scripts/agent.sh handoff FIX IMPLEMENTING; if ./scripts/agent.sh handoff FIX REVIEWED; then exit 1; fi; if ./scripts/agent.sh handoff FIX CODE_DONE; then exit 1; fi; ./scripts/agent.sh verify-handoff FIX; ./scripts/agent.sh validate FIX; cp .agents/runs/FIX/RUN.yaml "$scratch/run.original"; sed 's/base_sha: ".*"/base_sha: "PENDING"/' "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh validate FIX; then exit 1; fi; cp "$scratch/run.original" .agents/runs/FIX/RUN.yaml; sed 's/revision: ".*"/revision: "changed"/' "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/run.original" .agents/runs/FIX/RUN.yaml; cp .agents/modes/deterministic.yaml "$scratch/policy.original"; printf '\n# changed\n' >> .agents/modes/deterministic.yaml; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; mv "$scratch/policy.original" .agents/modes/deterministic.yaml
    git commit --allow-empty -qm planning-source-advanced; if ./scripts/agent.sh freshness FIX; then exit 1; fi; sed "s/base_sha: \".*\"/base_sha: \"$(git rev-parse HEAD)\"/" "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; mkdir -p .agents/runs/FIX/amendments; printf '# amendment\n' > .agents/runs/FIX/amendments/001.md; ./scripts/agent.sh refreeze FIX 001.md; ./scripts/agent.sh freshness FIX; cp .agents/runs/FIX/RUN.yaml "$scratch/source.original"; sed 's/type: local_markdown/type: none/; s/revision: ".*"/revision: not_applicable/' "$scratch/source.original" > .agents/runs/FIX/RUN.yaml; ./scripts/agent.sh freshness FIX; mv "$scratch/source.original" .agents/runs/FIX/RUN.yaml
    ./scripts/agent.sh verify-scope FIX
    printf 'agent touched dirty path\n' >> user-dirty.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; git checkout -- user-dirty.txt; printf 'user work\n' > user-dirty.txt
    printf 'agent touched untracked path\n' >> user-untracked.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; : > user-untracked.txt
    printf 'change\n' > authorized.txt; ./scripts/agent.sh verify-scope FIX; printf 'unexpected\n' > unexpected.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; rm unexpected.txt
    printf 'random\n' > .agents/runs/FIX/random.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; if ./scripts/agent.sh validate FIX; then exit 1; fi; rm .agents/runs/FIX/random.txt
    ./scripts/agent.sh handoff FIX VERIFIED; if ./scripts/agent.sh handoff FIX CODE_DONE; then exit 1; fi; ./scripts/agent.sh handoff FIX REVIEWED; ./scripts/agent.sh verify-handoff FIX; printf 'again\n' >> authorized.txt; if ./scripts/agent.sh handoff FIX REVIEWED; then exit 1; fi; ./scripts/agent.sh handoff FIX VERIFIED; ./scripts/agent.sh handoff FIX REVIEWED; ./scripts/agent.sh verify-handoff FIX; ./scripts/agent.sh handoff FIX CODE_DONE; ./scripts/agent.sh delivery-check FIX; if ./scripts/agent.sh handoff FIX VERIFIED; then exit 1; fi; printf 'post-review\n' >> authorized.txt; if ./scripts/agent.sh delivery-check FIX; then exit 1; fi; printf 'unauthorized\n' > delivery-unexpected.txt; if ./scripts/agent.sh delivery-check FIX; then exit 1; fi; rm delivery-unexpected.txt
    cp .agents/runs/FIX/EVIDENCE.md evidence.original; printf 'tamper\n' >> .agents/runs/FIX/EVIDENCE.md; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; mv evidence.original .agents/runs/FIX/EVIDENCE.md
    printf 'MISSING\n' > .agents/ACTIVE_RUN; if ./scripts/agent.sh status; then exit 1; fi; : > .agents/ACTIVE_RUN; ./scripts/agent.sh status | grep -Fxq 'active_task=none'; printf 'FIX\n' > .agents/ACTIVE_RUN
    printf '# index\n[[missing]]\n' > docs/wiki/index.md; if ./scripts/wiki-lint.sh; then exit 1; fi)
  echo 'agent control tests passed'
}

role_test() {
  tmp=$(mktemp -d /tmp/deterministic-role.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/ROLE/review" "$tmp/.agents/modes" "$tmp/scripts"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  printf 'ROLE\n' > "$tmp/.agents/ACTIVE_RUN"; printf '# Task\n' > "$tmp/.agents/runs/ROLE/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/ROLE/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/ROLE/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: none' '  revision: not_applicable' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/ROLE/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/ROLE/review/code-review.md"; printf '# verification\n' > "$tmp/.agents/runs/ROLE/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/ROLE/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email role@example.invalid; git config user.name fixture; : > authorized.txt; git add -- .agents scripts authorized.txt; git commit -qm baseline
    ./scripts/agent.sh role | grep -Fxq 'role=full_lifecycle'; AGENT_ROLE=full_lifecycle ./scripts/agent.sh role | grep -Fxq 'role=full_lifecycle'
    ./scripts/agent.sh baseline ROLE; ./scripts/agent.sh freeze ROLE; printf 'implementation\n' >> authorized.txt
    AGENT_ROLE=implementation_worker ./scripts/agent.sh role | grep -Fxq 'role=implementation_worker'; AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope ROLE; AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE IMPLEMENTING
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE VERIFIED; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE REVIEWED; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE CODE_DONE; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh freeze ROLE; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh refreeze ROLE 001.md; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh delivery-check ROLE; then exit 1; fi
    ./scripts/agent.sh handoff ROLE VERIFIED
    printf 'unplanned\n' > unplanned.txt; if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope ROLE; then exit 1; fi)
  echo 'agent role tests passed'
}

valid_role
command=${1:-}; case "$command" in
  role) printf 'role=%s\n' "$execution_role" ;;
  status) id=$(active_run); echo "active_task=${id:-none}"; echo "implementation_allowed=$( [ -n "$id" ] && echo true || echo false )"; effective "$id" ;;
  effective) effective "${2:-}" ;;
  baseline) require_full_lifecycle; baseline "${2:?usage: $0 baseline <TASK-ID>}" ;;
  freeze) require_full_lifecycle; freeze "${2:?usage: $0 freeze <TASK-ID>}" ;;
  refreeze) require_full_lifecycle; freeze "${2:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" refreeze "${3:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze <TASK-ID>}" ;;
  verify-scope) verify_scope "${2:?usage: $0 verify-scope <TASK-ID>}" ;;
  freshness) verify_freshness "${2:?usage: $0 freshness <TASK-ID>}" ;;
  handoff) [ "$execution_role" = full_lifecycle ] || [ "${3:-}" = IMPLEMENTING ] || fail "handoff phase denied for implementation_worker"; record_handoff "${2:?usage: $0 handoff <TASK-ID> <PHASE>}" "${3:?usage: $0 handoff <TASK-ID> <PHASE>}" ;;
  verify-handoff) verify_handoff "${2:?usage: $0 verify-handoff <TASK-ID>}" ;;
  delivery-check) require_full_lifecycle; delivery_check "${2:?usage: $0 delivery-check <TASK-ID>}" ;;
  validate) id=${2:?usage: $0 validate <TASK-ID>}; require_run "$id"; dir=$(run_dir "$id"); for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml review/code-review.md review/verification.md RESULT.md; do [ -f "$dir/$f" ] || fail "missing required artifact: $f"; done; validate_control_artifacts "$id"; scope_mappings "$dir/PLAN.md" >/dev/null; status=$(baseline_status "$dir"); if [ "$status" = captured ]; then validate_captured_baseline "$dir"; else historical_reference "$id" || fail "baseline missing or pending: $id"; fi; verify_freshness "$id"; verify_handoff "$id"; echo "run validated: $id" ;;
  test) require_full_lifecycle; fixture_test ;;
  role-test) require_full_lifecycle; role_test ;;
  *) echo "usage: $0 {role|status|effective|baseline|freeze|refreeze|verify-freeze|freshness|handoff|verify-handoff|delivery-check|validate|test|role-test} [TASK-ID]" >&2; exit 2 ;;
esac

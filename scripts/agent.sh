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
# True only when the key line itself exists (regardless of value), distinguishing a
# pre-branch-policy RUN.yaml (key entirely absent) from a new run awaiting `branch`.
section_key_present() { awk -v section="$2" -v key="$3" '$0 == section ":" { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && $0 ~ "^[[:space:]]*" key ":" { found=1 } END { exit !found }' "$1/RUN.yaml"; }
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

# Deterministic per-task Git branch isolation. A RUN.yaml with no repository.task_branch
# key at all predates this policy (e.g. EXAMPLE-001) and is never retroactively enforced —
# it stays inspectable exactly as it completed. A RUN.yaml that HAS the key is a new-style
# run and must have it resolved (not PENDING) with the working tree actually on it before
# any mutating lifecycle phase proceeds.
enforce_task_branch() {
  id=$1; dir=$(run_dir "$id")
  section_key_present "$dir" repository task_branch || return 0
  historical_reference "$id" && return 0
  expected=$(section_value "$dir" repository task_branch)
  case "$expected" in ''|PENDING) fail "task branch not established for $id; run '$0 branch $id' first" ;; esac
  current=$(git -C "$root" branch --show-current) || true
  [ -n "$current" ] || fail "detached HEAD: expected task branch $expected for $id"
  [ "$current" = "$expected" ] || fail "wrong git branch for $id: expected $expected, currently on $current"
}

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
  enforce_task_branch "$id"
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
  enforce_task_branch "$id"
  verify_freshness "$id"; verify_scope "$id"
  case "$phase" in IMPLEMENTING|VERIFIED|REVIEWED|CODE_DONE|DONE) ;; *) fail "invalid handoff phase";; esac
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
      # Lifecycle advancement out of IMPLEMENT must be backed by auditable
      # implementation_worker evidence (or a validated TDD exemption) for
      # every non-exempt behavior-changing scope path — this is the concrete
      # mechanism preventing a full_lifecycle session from silently
      # implementing application code itself and then advancing the state
      # machine as though delegation occurred. No-op for a pre-hardening run
      # (see policy_enforced) or a historical reference.
      verify_worker_evidence "$id"
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
    DONE)
      case "$current" in CODE_DONE|DONE) ;; *) fail "illegal handoff transition: $current -> $phase";; esac
      [ "$(section_value "$dir" handoff code_done_patch_sha256)" = "$patch" ] || fail "DONE blocked: CODE_DONE stale or missing"
      section_key_present "$dir" completion_report required && {
        ks=$(section_value "$dir" execution knowledge_state)
        case "$ks" in KNOWLEDGE_DONE|not_applicable) ;; *) fail "DONE blocked: knowledge transaction not recorded complete (see 'agent.sh knowledge-done')" ;; esac
        verify_completion_report "$id"
      } ;;
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
  enforce_task_branch "$id"
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
    ".agents/runs/$id/TASK.md"|".agents/runs/$id/EVIDENCE.md"|".agents/runs/$id/PLAN.md"|".agents/runs/$id/RUN.yaml"|".agents/runs/$id/RESULT.md"|".agents/runs/$id/COMPLETION_REPORT.md"|".agents/runs/$id/review/code-review.md"|".agents/runs/$id/review/verification.md"|".agents/runs/$id/amendments/"*|".agents/runs/$id/worker-evidence/"*) return 0 ;;
  esac
  # A published completion report legitimately (and only then) mutates the
  # task's own task_source.path via a task-integration adapter — see
  # publish_completion_report. That single, narrowly-scoped, full_lifecycle-
  # only write is treated as control metadata, exactly like this run's own
  # RESULT.md, rather than application scope drift. Before publication this
  # exemption does not apply, so an unrelated mid-IMPLEMENT edit to the task
  # source file is still correctly flagged.
  rundir=$(run_dir "$id")
  if [ "$(section_value "$rundir" completion_report published)" = true ]; then
    source_path=$(section_value "$rundir" task_source path)
    [ -n "$source_path" ] && [ "$path" = "$source_path" ] && return 0
  fi
  return 1
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
# ---------------------------------------------------------------------------
# Worker-evidence, TDD, and completion-report enforcement (policy-gated).
#
# A run is subject to this policy only when its RUN.yaml contains the
# `worker_evidence:` key block, exactly mirroring how `repository.task_branch`
# gates branch-isolation policy: a run created before this policy existed
# (EXAMPLE-001, and any run frozen before this change) has no such key, is
# never retroactively rewritten to add one, and is therefore exempt — see
# `historical_reference` / `enforce_task_branch` for the established pattern
# this reuses. A new run's template includes the key going forward.
# ---------------------------------------------------------------------------
policy_enforced() { section_key_present "$1" worker_evidence required; }

# Execution topology is a separate concept from agent role: it says whether
# a run needs a second, delegated implementation owner at all, not which
# vendor plays which part. `standalone` — the active full_lifecycle agent
# implements its own RED/GREEN evidence (no implementation_worker required
# or expected). `orchestrated` — full_lifecycle must delegate RED/GREEN/
# REFACTOR/fix implementation to implementation_worker and must not
# implement application code itself. A run's own RUN.yaml
# (execution.topology) wins when set to a valid value; otherwise this falls
# back to .agents/config.yaml's default_topology. Fails closed if neither
# resolves to a valid value, rather than silently guessing a topology.
resolve_topology() {
  dir=$1
  topology=$(section_value "$dir" execution topology)
  case "$topology" in standalone|orchestrated) printf '%s\n' "$topology"; return 0 ;; esac
  topology=$(config_value default_topology "$config")
  case "$topology" in
    standalone|orchestrated) printf '%s\n' "$topology"; return 0 ;;
    *) fail "no valid execution topology resolved: set execution.topology in RUN.yaml or default_topology in .agents/config.yaml" ;;
  esac
}
# The single agent role expected to author RED/GREEN/REFACTOR/FIX
# implementation evidence under a given topology. This is the only place
# topology is translated into a role expectation — everything else
# (record_worker_evidence, valid_evidence_file) consumes this, never
# hardcodes "implementation_worker" or "full_lifecycle" as a universal owner.
# Caveat (see .agents/ENFORCEMENT.md "Evidence strength"): this cannot
# cryptographically prove which process recorded a given evidence file —
# AGENT_ROLE remains a declared claim, not a proven identity, in both
# directions (a full_lifecycle session could still export
# AGENT_ROLE=implementation_worker itself in orchestrated mode, exactly as
# it could claim AGENT_ROLE=full_lifecycle in standalone mode). The optional
# Codex-session cross-check in valid_evidence_file narrows, but does not
# close, that residual gap.
expected_implementation_owner() {
  case "$1" in
    standalone) printf 'full_lifecycle\n' ;;
    orchestrated) printf 'implementation_worker\n' ;;
    *) fail "invalid execution topology: $1" ;;
  esac
}

# A small denylist of non-answers. This cannot judge whether a justification
# is semantically correct (that remains a human/reviewer judgment, recorded
# in review/code-review.md — see the RED-VALIDATED convention below); it only
# rejects the specific empty phrases the task explicitly called out, plus an
# unconditional minimum length so a single word cannot pass either.
reject_generic_justification() {
  text=$1
  norm=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
  case "$norm" in
    ''|'tdd not needed'|'test not needed'|'no test needed'|'not needed'|'configuration change'|'n/a'|'na') return 1 ;;
  esac
  [ "${#norm}" -ge 20 ] || return 1
  return 0
}

worker_evidence_dir() { printf '%s/worker-evidence\n' "$(run_dir "$1")"; }
next_evidence_seq() {
  dir=$1 phase=$2 n=0
  for f in "$dir"/"$phase"-*.yaml; do
    [ -e "$f" ] || continue
    seq=$(basename "$f" .yaml); seq=${seq#"$phase"-}
    case "$seq" in *[!0-9]*|'') continue ;; esac
    [ "$seq" -gt "$n" ] && n=$seq
  done
  printf '%d\n' $((n + 1))
}
evidence_field() { sed -n "s/^$2: *//p" "$1" | head -1 | tr -d '"'; }
evidence_targets() { sed -n 's/^target: *//p' "$1" | head -1 | tr ',' '\n'; }
evidence_covers_path() { evidence_targets "$1" | grep -Fxq "$2"; }

# Records one implementation-evidence file for the active run's current
# IMPLEMENTING phase. The role allowed to call this is derived from the
# run's resolved execution topology (see expected_implementation_owner) —
# never hardcoded to implementation_worker — only while the run's own
# frozen plan/evidence/task hashes are the ones this file records against —
# a later refreeze (amendment) makes every prior evidence file stale for
# verify_worker_evidence even though the files themselves are never deleted
# or rewritten (append-only audit trail).
#
# Reads structured fields from stdin as `key: value` lines: command, target
# (comma-separated scope paths), and, for phase=RED only, expected_failure.
record_worker_evidence() {
  id=$1 phase=$2 result=$3; require_run "$id"; dir=$(run_dir "$id")
  topology=$(resolve_topology "$dir") || return 1
  expected_role=$(expected_implementation_owner "$topology") || return 1
  [ "$execution_role" = "$expected_role" ] || fail "command requires AGENT_ROLE=$expected_role for this run's execution topology ($topology)"
  case "$phase" in RED|GREEN|REFACTOR|FIX) ;; *) fail "invalid worker-evidence phase: $phase" ;; esac
  case "$result" in pass|fail) ;; *) fail "invalid worker-evidence result: $result (want pass|fail)" ;; esac
  [ "$(section_value "$dir" handoff state)" = IMPLEMENTING ] || fail "worker evidence may only be recorded while handoff state is IMPLEMENTING"
  verify_freeze "$id"
  enforce_task_branch "$id"
  scratch=$(mktemp "${TMPDIR:-/tmp}/agent-worker-evidence.XXXXXX"); cat > "$scratch"
  command_text=$(sed -n 's/^command: *//p' "$scratch" | head -1)
  target_text=$(sed -n 's/^target: *//p' "$scratch" | head -1)
  expected_failure=$(sed -n 's/^expected_failure: *//p' "$scratch" | head -1)
  [ -n "$command_text" ] || { rm -f "$scratch"; fail "worker evidence requires a non-empty command"; }
  [ -n "$target_text" ] || { rm -f "$scratch"; fail "worker evidence requires a non-empty target (comma-separated scope paths)"; }
  mappings=$(scope_mappings "$dir/PLAN.md") || { rm -f "$scratch"; fail "invalid scope mapping"; }
  printf '%s\n' "$target_text" | tr ',' '\n' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    authorized_path "$mappings" "$p" || { echo "worker evidence targets a path outside frozen scope: $p" >&2; exit 1; }
  done || { rm -f "$scratch"; fail "worker evidence rejected: out-of-scope target"; }
  if [ "$phase" = RED ]; then
    [ "$result" = fail ] || { rm -f "$scratch"; fail "RED evidence must record result: fail"; }
    reject_generic_justification "$expected_failure" || { rm -f "$scratch"; fail "RED evidence requires a specific, non-generic expected_failure (>=20 chars, not a stock phrase)"; }
  else
    [ "$result" = pass ] || { rm -f "$scratch"; fail "$phase evidence must record result: pass"; }
  fi
  evdir=$(worker_evidence_dir "$id"); mkdir -p "$evdir"
  seq=$(next_evidence_seq "$evdir" "$phase")
  out="$evdir/$phase-$seq.yaml"
  {
    printf 'task_id: "%s"\n' "$id"
    printf 'phase: "%s"\n' "$phase"
    printf 'result: "%s"\n' "$result"
    printf 'role: "%s"\n' "$execution_role"
    printf 'topology: "%s"\n' "$topology"
    printf 'command: %s\n' "$command_text"
    printf 'target: %s\n' "$target_text"
    [ "$phase" = RED ] && printf 'expected_failure: %s\n' "$expected_failure"
    printf 'base_sha: "%s"\n' "$(git -C "$root" rev-parse HEAD)"
    printf 'task_sha256: "%s"\n' "$(section_value "$dir" freeze task_sha256)"
    printf 'evidence_sha256: "%s"\n' "$(section_value "$dir" freeze evidence_sha256)"
    printf 'plan_sha256: "%s"\n' "$(section_value "$dir" freeze plan_sha256)"
    [ -n "${CODEX_SESSION_ID:-}" ] && printf 'codex_session_id: "%s"\n' "$CODEX_SESSION_ID"
    printf 'timestamp: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$out"
  rm -f "$scratch"
  echo "worker evidence recorded: $id $phase-$seq ($result)"
}

# Structural, task/freeze/topology-bound validity of one evidence file:
# current role claim aside (a script cannot cryptographically prove which
# process recorded it — see AGENT_ROLE's caveat elsewhere), this checks
# everything a script legitimately can — it belongs to this task, it was
# recorded against the exact plan/evidence/task hashes currently frozen (a
# stale or cross-task file fails), it was authored by the role this run's
# CURRENT resolved execution topology expects (not a hardcoded vendor — a
# standalone run rejects implementation_worker-authored evidence exactly as
# an orchestrated run rejects full_lifecycle-authored evidence), and, when a
# local Codex session log directory is discoverable, an optional cross-check
# that a referenced Codex session actually exists and ran against this repo.
valid_evidence_file() {
  id=$1 dir=$2 file=$3 expected_role=$4
  [ "$(evidence_field "$file" task_id)" = "$id" ] || return 1
  [ "$(evidence_field "$file" task_sha256)" = "$(section_value "$dir" freeze task_sha256)" ] || return 1
  [ "$(evidence_field "$file" evidence_sha256)" = "$(section_value "$dir" freeze evidence_sha256)" ] || return 1
  [ "$(evidence_field "$file" plan_sha256)" = "$(section_value "$dir" freeze plan_sha256)" ] || return 1
  [ "$(evidence_field "$file" role)" = "$expected_role" ] || return 1
  session=$(evidence_field "$file" codex_session_id)
  if [ -n "$session" ] && [ -d "${CODEX_SESSION_DIR:-$HOME/.codex/sessions}" ]; then
    grep -RFl "\"$session\"" "${CODEX_SESSION_DIR:-$HOME/.codex/sessions}" >/dev/null 2>&1 || return 1
  fi
  return 0
}

parse_tdd_exemptions() {
  awk '
    /^scope:$/ { inside=1; next } inside && /^---$/ { exit }
    inside && /^  - path: / { path=$0; sub(/^  - path: /, "", path); exemption=""; next }
    inside && /^    tdd_exemption: / { e=$0; sub(/^    tdd_exemption: /, "", e); exemption=e; print path "|" exemption }
  ' "$1"
}
exempted_path() { parse_tdd_exemptions "$1" | grep -F "$2|" | head -1 | cut -d '|' -f2-; }
validate_tdd_exemptions() {
  dir=$1; mappings=$(scope_mappings "$dir/PLAN.md") || fail "invalid scope mapping"
  printf '%s\n' "$mappings" | cut -d '|' -f1 | while IFS= read -r path; do
    [ -n "$path" ] || continue
    reason=$(exempted_path "$dir/PLAN.md" "$path")
    [ -n "$reason" ] || continue
    reject_generic_justification "$reason" && continue
    echo "invalid TDD exemption for $path: reason is missing or too generic" >&2
    exit 1
  done || fail "TDD exemption validation failed"
}

# The verification gate for behavior-changing scope: every frozen scope path
# without a tdd_exemption must have at least one valid RED (result=fail) and
# at least one valid GREEN-or-FIX (result=pass) implementation-evidence file
# naming it, both bound to the currently frozen plan/evidence/task hashes
# AND authored by the role this run's current execution topology expects
# (see resolve_topology/expected_implementation_owner — standalone expects
# full_lifecycle, orchestrated expects implementation_worker; evidence from
# the other role is rejected exactly like stale or cross-task evidence). A
# path carrying a validated tdd_exemption needs neither. Skips entirely for
# a run not subject to this policy (see policy_enforced) or a historical
# reference.
verify_worker_evidence() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  historical_reference "$id" && { echo "worker-evidence historical reference: $id"; return 0; }
  policy_enforced "$dir" || { echo "worker-evidence not policy-enforced for $id (pre-hardening run)"; return 0; }
  verify_freeze "$id"
  validate_tdd_exemptions "$dir"
  topology=$(resolve_topology "$dir") || return 1
  expected_role=$(expected_implementation_owner "$topology") || return 1
  evdir=$(worker_evidence_dir "$id")
  mappings=$(scope_mappings "$dir/PLAN.md") || fail "invalid scope mapping"
  missing_tmp=$(mktemp "${TMPDIR:-/tmp}/agent-missing-evidence.XXXXXX")
  printf '%s\n' "$mappings" | cut -d '|' -f1 | while IFS= read -r path; do
    [ -n "$path" ] || continue
    reason=$(exempted_path "$dir/PLAN.md" "$path"); [ -n "$reason" ] && continue
    red_ok=0 green_ok=0
    if [ -d "$evdir" ]; then
      for f in "$evdir"/RED-*.yaml; do
        [ -e "$f" ] || continue
        evidence_covers_path "$f" "$path" || continue
        valid_evidence_file "$id" "$dir" "$f" "$expected_role" && red_ok=1
      done
      for f in "$evdir"/GREEN-*.yaml "$evdir"/FIX-*.yaml; do
        [ -e "$f" ] || continue
        evidence_covers_path "$f" "$path" || continue
        valid_evidence_file "$id" "$dir" "$f" "$expected_role" && green_ok=1
      done
    fi
    if [ "$red_ok" != 1 ] || [ "$green_ok" != 1 ]; then printf '%s\n' "$path" >> "$missing_tmp"; fi
  done
  missing=$(cat "$missing_tmp"); rm -f "$missing_tmp"
  [ -z "$missing" ] || { echo "missing valid RED+GREEN implementation evidence (topology=$topology, expected role=$expected_role; or TDD exemption) for:" >&2; printf '%s\n' "$missing" >&2; fail "worker-evidence verification failed: $id"; }
  echo "worker-evidence verified: $id (topology=$topology)"
}

# --- Task Completion Report (task-system agnostic) -------------------------
#
# agent.sh never talks to a specific task tracker. It only (a) checks the
# report's minimum structure, (b) delegates publish/verify to a pluggable
# adapter script under .agents/task-integrations/<name>.sh implementing
# `publish <TASK-ID> <report-file>` (prints a receipt to stdout) and
# `verify <TASK-ID> <receipt>` (exit 0 iff still present/correct there), and
# (c) records the adapter name + receipt in RUN.yaml. What "publish" means —
# append to a Markdown task file, comment on an issue, etc. — is entirely the
# adapter's concern.
required_report_headings() {
  dir=$1
  printf '## Implementation Summary\n## Verification\n## Review Result\n## Known Limitations / Follow-up\n'
  [ -d "$(worker_evidence_dir "$(basename "$dir")")" ] && printf '## TDD Evidence\n'
  [ -d "$dir/amendments" ] && [ -n "$(ls -A "$dir/amendments" 2>/dev/null)" ] && printf '## Amendments\n'
}
validate_completion_report_structure() {
  id=$1 dir=$(run_dir "$1"); report="$dir/COMPLETION_REPORT.md"
  [ -f "$report" ] || fail "completion report missing: $report"
  size=$(wc -c < "$report" | tr -d ' '); [ "$size" -ge 200 ] || fail "completion report is too short to be meaningful"
  required_report_headings "$dir" | while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    grep -Fq "$heading" "$report" || { echo "completion report missing required section: $heading" >&2; exit 1; }
  done || fail "completion report structure invalid: $id"
}
adapter_script() {
  name=$1; path="$root/.agents/task-integrations/$name.sh"
  [ -f "$path" ] || fail "unknown task-integration adapter: $name"
  printf '%s\n' "$path"
}
publish_completion_report() {
  id=$1 adapter=${2:-markdown}; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  [ "$(run_state "$dir")" = CODE_DONE ] || fail "completion report may only be published after CODE_DONE"
  validate_completion_report_structure "$id"
  script=$(adapter_script "$adapter") || return 1
  receipt=$("$script" publish "$id" "$dir/COMPLETION_REPORT.md") || fail "completion report publish failed via adapter: $adapter"
  [ -n "$receipt" ] || fail "adapter $adapter returned an empty receipt"
  tmp=$dir/RUN.yaml.tmp
  replace_section_value "$dir" completion_report adapter "$adapter" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  replace_section_value "$dir" completion_report published true "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
  replace_section_value "$dir" completion_report receipt "$receipt" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
  # An adapter (e.g. markdown.sh) may append the report into the task's own
  # task_source.path file, changing its hash. That specific, narrowly-scoped
  # write is this command's own authorized effect (never a scope drift being
  # masked), so the recorded freshness revision is refreshed to match it —
  # otherwise every later handoff call's unconditional verify_freshness
  # would wrongly report the plan as stale for a run that is already
  # CODE_DONE and has nothing left to re-plan.
  set_task_source_revision "$dir"
  echo "completion report published: $id via $adapter -> $receipt"
}
verify_completion_report() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  [ "$(section_value "$dir" completion_report published)" = true ] || fail "completion report not published: $id"
  adapter=$(section_value "$dir" completion_report adapter); receipt=$(section_value "$dir" completion_report receipt)
  [ -n "$adapter" ] && [ -n "$receipt" ] || fail "completion report adapter/receipt missing: $id"
  script=$(adapter_script "$adapter") || return 1
  "$script" verify "$id" "$receipt" || fail "completion report publication could not be verified: $id"
  echo "completion report publication verified: $id"
}
knowledge_done() {
  id=$1 state=${2:-KNOWLEDGE_DONE}; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  case "$state" in KNOWLEDGE_DONE|not_applicable) ;; *) fail "invalid knowledge state: $state" ;; esac
  [ "$(run_state "$dir")" = CODE_DONE ] || fail "knowledge-done requires CODE_DONE first"
  section_key_present "$dir" execution knowledge_state || fail "run schema has no execution.knowledge_state field to set (pre-hardening run)"
  tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" execution knowledge_state "$state" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  echo "knowledge state recorded: $id $state"
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
  id=$1; require_run "$id"; dir=$(run_dir "$id"); enforce_task_branch "$id"; mappings=$(scope_mappings "$dir/PLAN.md") || fail "invalid scope mapping"; [ -n "$mappings" ] || fail "scope mapping missing"
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
  enforce_task_branch "$id"
  if freeze_hash_present "$dir"; then [ "${2:-}" = refreeze ] && [ -n "${3:-}" ] && [ -f "$dir/amendments/$3" ] || fail "existing freeze requires explicit amendment"; fi
  set_task_source_revision "$dir"; tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"; mv "$tmp" "$dir/RUN.yaml"; echo "freeze recorded: $id"
}

# Deterministic, ASCII-safe, hyphenated slug — no timestamps, no random suffixes.
# local_markdown reuses the task source file's own canonical basename; `none` (used only by
# this file's own role/self-test fixtures) has no title to derive from, so it is a fixed
# constant. Either way the result is a pure function of already-frozen task metadata.
derive_task_slug() {
  dir=$1; id=$(section_value "$dir" task id); type=$(section_value "$dir" task_source type)
  case "$type" in
    local_markdown)
      path=$(section_value "$dir" task_source path); base=$(basename "$path" .md)
      case "$base" in "$id"-*) slug=${base#"$id"-} ;; *) slug=$base ;; esac ;;
    none) slug=run ;;
    *) fail "task source adapter unavailable for slug derivation: ${type:-missing}" ;;
  esac
  slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$slug" ] || fail "derived task slug is empty for $id"
  printf '%s\n' "$slug"
}

# Establishes (or, on resume, re-attaches to) this run's dedicated task/<TASK-ID>-<slug>
# branch, created from the canonical integration branch's exact current tip — never from
# whatever HEAD happens to be. Full-lifecycle only: an implementation_worker must never
# create or switch branches. Must run before baseline; a CODE_DONE run's branch is fixed.
branch_setup() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "cannot modify task branch on CODE_DONE run: $id"
  canonical=$(config_value canonical_branch "$config"); [ -n "$canonical" ] || fail "canonical_branch not configured"
  current=$(git -C "$root" branch --show-current) || true
  [ -n "$current" ] || fail "task branch setup requires a checked-out branch, not detached HEAD"
  existing=$(section_value "$dir" repository task_branch)
  case "$existing" in
    ''|PENDING)
      [ "$current" = "$canonical" ] || fail "task branch setup must start from canonical branch ($canonical); currently on: $current"
      bstatus=$(baseline_status "$dir"); case "$bstatus" in ''|pending) ;; *) fail "task branch setup must occur before baseline: $id";; esac
      canonical_sha=$(git -C "$root" rev-parse "refs/heads/$canonical") || fail "canonical branch not found locally: $canonical"
      slug=$(derive_task_slug "$dir") || return 1
      task_branch="task/$id-$slug"
      if git -C "$root" show-ref --verify --quiet "refs/heads/$task_branch"; then
        branch_sha=$(git -C "$root" rev-parse "refs/heads/$task_branch")
        [ "$branch_sha" = "$canonical_sha" ] || fail "existing branch $task_branch is not compatible with canonical base $canonical_sha; will not reuse or overwrite"
      else
        git -C "$root" branch "$task_branch" "$canonical_sha" || fail "failed to create task branch: $task_branch"
      fi
      git -C "$root" checkout "$task_branch" || fail "failed to switch to task branch: $task_branch"
      tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" repository canonical_branch "$canonical" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
      tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" repository task_branch "$task_branch" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
      echo "task branch established: $id $task_branch" ;;
    *)
      git -C "$root" show-ref --verify --quiet "refs/heads/$existing" || fail "recorded task branch missing: $existing; will not regenerate, recover manually"
      if [ "$current" != "$existing" ]; then
        [ "$current" = "$canonical" ] || fail "cannot resume $id: on unexpected branch $current (expected $canonical or $existing)"
        git -C "$root" checkout "$existing" || fail "failed to switch to recorded task branch: $existing"
      fi
      echo "task branch resumed: $id $existing" ;;
  esac
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

# Proves the worker-evidence / TDD / completion-report enforcement under
# execution.topology: orchestrated: a full_lifecycle orchestrator cannot
# silently implement application code and advance past IMPLEMENT (the
# concrete KW-002 bypass), evidence is bound to the current task/freeze
# (stale and cross-task evidence are rejected), evidence must be authored by
# the role orchestrated topology expects — implementation_worker, not the
# orchestrator itself — a worker cannot record evidence for an out-of-scope
# path, a validated TDD exemption substitutes for RED/GREEN, and DONE
# requires a published, independently-verifiable completion report plus a
# recorded knowledge-transaction state — never the other way around. See
# standalone_test for the complementary execution.topology: standalone case.
policy_test() {
  tmp=$(mktemp -d /tmp/deterministic-policy.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/POLICY/review" "$tmp/.agents/modes" "$tmp/.agents/task-integrations" "$tmp/scripts" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  cp "$root/.agents/task-integrations/markdown.sh" "$tmp/.agents/task-integrations/"; chmod +x "$tmp/.agents/task-integrations/markdown.sh"
  printf 'POLICY\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: POLICY\n\n## Acceptance criteria\n\n- AC-1: impl.txt behavior\n- AC-2: config.txt constant\n' > "$tmp/.agents/runs/POLICY/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/POLICY/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' \
    '  - path: impl.txt' '    criteria: [AC-1]' \
    '  - path: config.txt' '    criteria: [AC-2]' \
    '    tdd_exemption: "control-plane configuration constant with no executable behavior to test"' \
    '---' '# Plan' > "$tmp/.agents/runs/POLICY/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/POLICY.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/POLICY/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/POLICY/review/code-review.md"; printf '# verification\n' > "$tmp/.agents/runs/POLICY/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/POLICY/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email policy@example.invalid; git config user.name fixture
    printf '# POLICY task\n' > tasks/POLICY.md; : > impl.txt; : > config.txt
    git add -- .agents scripts tasks impl.txt config.txt; git commit -qm baseline

    ./scripts/agent.sh baseline POLICY
    printf 'discovered\n' >> .agents/runs/POLICY/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/POLICY/PLAN.md
    ./scripts/agent.sh freeze POLICY
    ./scripts/agent.sh handoff POLICY IMPLEMENTING

    # A full_lifecycle session implements the change directly (exactly the
    # KW-002 pattern) and then tries to advance the lifecycle as though
    # delegation had occurred. This must be rejected: no worker evidence
    # exists yet for either scope path.
    printf 'implemented directly by full_lifecycle\n' > impl.txt
    if ./scripts/agent.sh handoff POLICY VERIFIED; then echo "FAIL: full_lifecycle bypass was not rejected" >&2; exit 1; fi
    git checkout -q -- impl.txt

    # Recording worker evidence is worker-only.
    if printf 'command: go test ./...\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence POLICY GREEN pass; then
      echo "FAIL: full_lifecycle was allowed to record worker evidence" >&2; exit 1
    fi

    # A worker cannot claim evidence for a path outside frozen scope.
    if printf 'command: go test ./...\ntarget: out-of-scope.txt\n' | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence POLICY GREEN pass; then
      echo "FAIL: out-of-scope worker evidence was accepted" >&2; exit 1
    fi

    # Orchestrated topology rejects evidence authored by the orchestrator
    # role, even if it is otherwise perfectly task/freeze/scope bound — this
    # is the corrected-architecture proof that worker ownership is actually
    # enforced by role, not merely by whichever role happened to call the
    # command. Hand-craft what a full_lifecycle-authored file would look
    # like (record_worker_evidence itself already refuses to write one, so
    # this simulates one slipping in some other way) and confirm rejection.
    mkdir -p .agents/runs/POLICY/worker-evidence
    {
      printf 'task_id: "POLICY"\nphase: "GREEN"\nresult: "pass"\nrole: "full_lifecycle"\ntopology: "orchestrated"\n'
      printf 'command: go test ./...\ntarget: impl.txt\n'
      printf 'base_sha: "%s"\n' "$(git rev-parse HEAD)"
      printf 'task_sha256: "%s"\n' "$(sed -n 's/^[[:space:]]*task_sha256: *//p' .agents/runs/POLICY/RUN.yaml | head -1 | tr -d '"')"
      printf 'evidence_sha256: "%s"\n' "$(sed -n 's/^[[:space:]]*evidence_sha256: *//p' .agents/runs/POLICY/RUN.yaml | head -1 | tr -d '"')"
      printf 'plan_sha256: "%s"\n' "$(sed -n 's/^[[:space:]]*plan_sha256: *//p' .agents/runs/POLICY/RUN.yaml | head -1 | tr -d '"')"
    } > .agents/runs/POLICY/worker-evidence/GREEN-orchestrator-forged.yaml
    if ./scripts/agent.sh verify-worker-evidence POLICY; then
      echo "FAIL: orchestrator-authored (role=full_lifecycle) evidence counted under orchestrated topology" >&2; exit 1
    fi
    rm .agents/runs/POLICY/worker-evidence/GREEN-orchestrator-forged.yaml

    # GREEN with result=fail is invalid; RED with result=pass is invalid;
    # RED with a generic/too-short expected_failure is invalid.
    if printf 'command: go test ./...\ntarget: impl.txt\n' | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence POLICY GREEN fail; then exit 1; fi
    if printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: irrelevant\n' | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence POLICY RED pass; then exit 1; fi
    if printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: configuration change\n' | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence POLICY RED fail; then exit 1; fi

    # GREEN recorded before any RED exists is not sufficient on its own.
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence POLICY GREEN pass"
    if ./scripts/agent.sh handoff POLICY VERIFIED; then echo "FAIL: VERIFIED allowed with GREEN but no valid RED" >&2; exit 1; fi

    # A genuine RED (fails for a specific, named behavioral reason) plus the
    # GREEN already recorded above now satisfies impl.txt; config.txt is
    # covered by its validated tdd_exemption. VERIFIED must now succeed.
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\nexpected_failure: TestImpl fails: registry returns zero tasks before the new lookup method exists\n' | ./scripts/agent.sh worker-evidence POLICY RED fail"
    ./scripts/agent.sh handoff POLICY VERIFIED

    # Stale evidence rejection (distinct from cross-task rejection below): an
    # evidence file whose recorded plan_sha256 no longer matches the run's
    # currently frozen plan (as a refreeze/amendment would cause) must stop
    # counting, even though it still belongs to this exact task.
    cp .agents/runs/POLICY/worker-evidence/GREEN-1.yaml .agents/runs/POLICY/worker-evidence/GREEN-1.yaml.bak
    sed -i.tmp 's/^plan_sha256: .*/plan_sha256: "0000000000000000000000000000000000000000000000000000000000000000"/' .agents/runs/POLICY/worker-evidence/GREEN-1.yaml
    rm -f .agents/runs/POLICY/worker-evidence/GREEN-1.yaml.tmp
    if ./scripts/agent.sh verify-worker-evidence POLICY; then echo "FAIL: staled (plan_sha256-mismatched) evidence still counted" >&2; exit 1; fi
    mv .agents/runs/POLICY/worker-evidence/GREEN-1.yaml.bak .agents/runs/POLICY/worker-evidence/GREEN-1.yaml
    ./scripts/agent.sh verify-worker-evidence POLICY

    ./scripts/agent.sh handoff POLICY REVIEWED
    ./scripts/agent.sh handoff POLICY CODE_DONE

    # Completion report gating: DONE is unreachable before it is published,
    # unreachable before knowledge state is recorded, and the markdown
    # adapter's receipt genuinely round-trips against the task source file.
    if ./scripts/agent.sh handoff POLICY DONE; then echo "FAIL: DONE allowed before completion report" >&2; exit 1; fi
    if ./scripts/agent.sh publish-completion-report POLICY markdown; then echo "FAIL: publish allowed before a report file exists" >&2; exit 1; fi
    printf '%s\n' '# Completion Report: POLICY' '' '## Implementation Summary' 'impl.txt gained Find(); config.txt is a constant, TDD-exempt.' '' \
      '## TDD Evidence' 'RED: TestImpl failed for the expected reason; GREEN: passed after implementation.' '' \
      '## Verification' 'go test ./... passed.' '' '## Review Result' 'Approved.' '' '## Known Limitations / Follow-up' 'None.' \
      > .agents/runs/POLICY/COMPLETION_REPORT.md
    if ./scripts/agent.sh handoff POLICY DONE; then echo "FAIL: DONE allowed before publication" >&2; exit 1; fi
    ./scripts/agent.sh publish-completion-report POLICY markdown
    grep -Fq 'COMPLETION-REPORT:BEGIN:POLICY' tasks/POLICY.md
    if ./scripts/agent.sh handoff POLICY DONE; then echo "FAIL: DONE allowed before knowledge-done" >&2; exit 1; fi
    ./scripts/agent.sh knowledge-done POLICY not_applicable
    ./scripts/agent.sh verify-completion-report POLICY
    ./scripts/agent.sh handoff POLICY DONE

    # Tamper detection: editing the published section invalidates the
    # receipt even though the adapter's own file otherwise looks intact.
    sed -i.bak 's/impl.txt gained.*/tampered/' tasks/POLICY.md; rm -f tasks/POLICY.bak
    if ./scripts/agent.sh verify-completion-report POLICY; then echo "FAIL: tampered completion-report section still verified" >&2; exit 1; fi
    git checkout -q -- tasks/POLICY.md

    # Stale/cross-task evidence rejection, via a second run (POLICY2) reusing
    # a copy of POLICY's already-recorded (and now differently-frozen)
    # GREEN evidence file: its embedded task_id/hashes belong to POLICY, not
    # POLICY2, so it must never count toward POLICY2's own requirement.
    mkdir -p .agents/runs/POLICY2/review
    printf '# Task: POLICY2\n' > .agents/runs/POLICY2/TASK.md; printf '# Evidence\n' > .agents/runs/POLICY2/EVIDENCE.md
    printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > .agents/runs/POLICY2/PLAN.md
    printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/POLICY.md' '  revision: PENDING' \
      'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
      'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
      'baseline:' '  status: pending' \
      'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
      'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
      'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
      > .agents/runs/POLICY2/RUN.yaml
    printf '# review\n' > .agents/runs/POLICY2/review/code-review.md; printf '# verification\n' > .agents/runs/POLICY2/review/verification.md; printf '# result\n' > .agents/runs/POLICY2/RESULT.md
    printf 'POLICY2\n' > .agents/ACTIVE_RUN
    ./scripts/agent.sh baseline POLICY2; printf 'discovered\n' >> .agents/runs/POLICY2/EVIDENCE.md; printf 'planned\n' >> .agents/runs/POLICY2/PLAN.md; ./scripts/agent.sh freeze POLICY2
    ./scripts/agent.sh handoff POLICY2 IMPLEMENTING
    mkdir -p .agents/runs/POLICY2/worker-evidence
    cp .agents/runs/POLICY/worker-evidence/GREEN-1.yaml .agents/runs/POLICY2/worker-evidence/GREEN-1.yaml
    cp .agents/runs/POLICY/worker-evidence/RED-1.yaml .agents/runs/POLICY2/worker-evidence/RED-1.yaml
    if ./scripts/agent.sh handoff POLICY2 VERIFIED; then echo "FAIL: cross-task evidence (wrong task_id/hashes) was accepted" >&2; exit 1; fi
    printf 'POLICY\n' > .agents/ACTIVE_RUN)
  echo 'agent policy tests passed'
}

# Proves execution.topology: standalone — the complement of policy_test's
# orchestrated case. The generic control plane does not know or care which
# vendor is running as full_lifecycle here; this fixture is run twice under
# different task IDs/commentary ("Claude-like", "Codex-like") purely to make
# that vendor-neutrality concrete rather than asserted only by absence of
# vendor-specific code.
standalone_test() {
  tmp=$(mktemp -d /tmp/deterministic-standalone.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/STANDALONE/review" "$tmp/.agents/modes" "$tmp/.agents/task-integrations" "$tmp/scripts" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$root/scripts/worker-run.sh" "$tmp/scripts/"; chmod +x "$tmp/scripts/worker-run.sh"
  cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  cp "$root/.agents/task-integrations/markdown.sh" "$tmp/.agents/task-integrations/"; chmod +x "$tmp/.agents/task-integrations/markdown.sh"
  printf 'STANDALONE\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: STANDALONE\n\n## Acceptance criteria\n\n- AC-1: impl.txt behavior\n- AC-2: config.txt constant\n' > "$tmp/.agents/runs/STANDALONE/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/STANDALONE/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' \
    '  - path: impl.txt' '    criteria: [AC-1]' \
    '  - path: config.txt' '    criteria: [AC-2]' \
    '    tdd_exemption: "control-plane configuration constant with no executable behavior to test"' \
    '---' '# Plan' > "$tmp/.agents/runs/STANDALONE/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/STANDALONE.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: standalone' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/STANDALONE/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/STANDALONE/review/code-review.md"; printf '# verification\n' > "$tmp/.agents/runs/STANDALONE/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/STANDALONE/RESULT.md"
  (cd "$tmp"; git init -q; git config user.email standalone@example.invalid; git config user.name fixture
    printf '# STANDALONE task\n' > tasks/STANDALONE.md; : > impl.txt; : > config.txt
    git add -- .agents scripts tasks impl.txt config.txt; git commit -qm baseline

    ./scripts/agent.sh baseline STANDALONE
    printf 'discovered\n' >> .agents/runs/STANDALONE/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/STANDALONE/PLAN.md
    ./scripts/agent.sh freeze STANDALONE
    ./scripts/agent.sh handoff STANDALONE IMPLEMENTING

    # Under standalone topology, implementation_worker is not the expected
    # owner — the role that would be correct under orchestrated is now the
    # wrong one, symmetrically to policy_test's forged-evidence case.
    if printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: no such method yet\n' \
       | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence STANDALONE RED fail; then
      echo "FAIL: implementation_worker was allowed to record evidence under standalone topology" >&2; exit 1
    fi

    # worker-run.sh itself refuses to run at all against a standalone-topology
    # run (checked before even looking for a codex binary, so this needs no
    # real codex install to verify).
    if ./scripts/worker-run.sh STANDALONE RED --network not-required --prompt-file .agents/runs/STANDALONE/TASK.md; then
      echo "FAIL: worker-run.sh proceeded against a standalone-topology run" >&2; exit 1
    fi

    # (1) Standalone full_lifecycle implements the change directly — this is
    # correct and expected here, unlike policy_test's orchestrated case.
    printf 'implemented directly by the standalone full_lifecycle agent\n' > impl.txt

    # (4) Standalone must not use "no worker exists" as an excuse to skip
    # RED/GREEN: VERIFIED is still rejected with zero evidence recorded.
    if ./scripts/agent.sh handoff STANDALONE VERIFIED; then
      echo "FAIL: standalone VERIFIED succeeded with no RED/GREEN evidence at all" >&2; exit 1
    fi

    # (2) Valid RED, attributable to full_lifecycle (the default role — no
    # AGENT_ROLE override), is required and accepted.
    printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\nexpected_failure: TestImpl fails: registry returns zero tasks before the new lookup method exists\n' \
      | ./scripts/agent.sh worker-evidence STANDALONE RED fail
    if ./scripts/agent.sh handoff STANDALONE VERIFIED; then
      echo "FAIL: standalone VERIFIED succeeded with RED but no GREEN evidence" >&2; exit 1
    fi

    # (3) Valid GREEN, same role, completes the pair; config.txt's exemption
    # covers the other scope path exactly as under orchestrated topology.
    printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\n' \
      | ./scripts/agent.sh worker-evidence STANDALONE GREEN pass
    grep -Fq 'role: "full_lifecycle"' .agents/runs/STANDALONE/worker-evidence/RED-1.yaml
    grep -Fq 'role: "full_lifecycle"' .agents/runs/STANDALONE/worker-evidence/GREEN-1.yaml
    ./scripts/agent.sh handoff STANDALONE VERIFIED
    ./scripts/agent.sh handoff STANDALONE REVIEWED
    ./scripts/agent.sh handoff STANDALONE CODE_DONE

    # (14) Completion-report/DONE gating is identical in standalone mode.
    if ./scripts/agent.sh handoff STANDALONE DONE; then echo "FAIL: DONE allowed before completion report" >&2; exit 1; fi
    printf '%s\n' '# Completion Report: STANDALONE' '' '## Implementation Summary' 'impl.txt gained Find(); config.txt is a constant, TDD-exempt.' '' \
      '## TDD Evidence' 'RED: TestImpl failed for the expected reason; GREEN: passed after implementation. Both authored by the standalone full_lifecycle agent.' '' \
      '## Verification' 'go test ./... passed.' '' '## Review Result' 'Approved.' '' '## Known Limitations / Follow-up' 'None.' \
      > .agents/runs/STANDALONE/COMPLETION_REPORT.md
    ./scripts/agent.sh publish-completion-report STANDALONE markdown
    ./scripts/agent.sh knowledge-done STANDALONE not_applicable
    ./scripts/agent.sh verify-completion-report STANDALONE
    ./scripts/agent.sh handoff STANDALONE DONE)

  # (5, 6) The same mechanism, run again under a differently-labeled task,
  # accepts a second standalone full_lifecycle "identity" with zero
  # vendor-specific code anywhere in agent.sh — the control plane never
  # branches on Claude vs. Codex, only on execution_role/topology.
  tmp2=$(mktemp -d /tmp/deterministic-standalone2.XXXXXX)
  mkdir -p "$tmp2/.agents/runs/STANDALONE2/review" "$tmp2/.agents/modes" "$tmp2/scripts" "$tmp2/tasks"
  cp "$root/scripts/agent.sh" "$tmp2/scripts/"; cp "$root/.agents/config.yaml" "$tmp2/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp2/.agents/modes/"
  printf 'STANDALONE2\n' > "$tmp2/.agents/ACTIVE_RUN"
  printf '# Task: STANDALONE2 (simulating a standalone Codex-like session)\n' > "$tmp2/.agents/runs/STANDALONE2/TASK.md"
  printf '# Evidence\n' > "$tmp2/.agents/runs/STANDALONE2/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp2/.agents/runs/STANDALONE2/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/STANDALONE2.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: standalone' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp2/.agents/runs/STANDALONE2/RUN.yaml"
  printf '# review\n' > "$tmp2/.agents/runs/STANDALONE2/review/code-review.md"; printf '# verification\n' > "$tmp2/.agents/runs/STANDALONE2/review/verification.md"; printf '# result\n' > "$tmp2/.agents/runs/STANDALONE2/RESULT.md"
  (cd "$tmp2"; git init -q; git config user.email standalone2@example.invalid; git config user.name fixture
    printf '# STANDALONE2 task\n' > tasks/STANDALONE2.md; : > impl.txt
    git add -- .agents scripts tasks impl.txt; git commit -qm baseline
    ./scripts/agent.sh baseline STANDALONE2
    printf 'discovered\n' >> .agents/runs/STANDALONE2/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/STANDALONE2/PLAN.md
    ./scripts/agent.sh freeze STANDALONE2
    ./scripts/agent.sh handoff STANDALONE2 IMPLEMENTING
    printf 'implemented directly by a second, differently-identified standalone agent\n' > impl.txt
    printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: lookup not implemented yet\n' \
      | ./scripts/agent.sh worker-evidence STANDALONE2 RED fail
    printf 'command: go test ./...\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence STANDALONE2 GREEN pass
    ./scripts/agent.sh handoff STANDALONE2 VERIFIED)
  rm -rf "$tmp2"
  echo 'agent standalone tests passed'
}

# Deterministic per-task branch isolation. A run whose RUN.yaml has no repository.task_branch
# key (like FIX/ROLE above, and like the real EXAMPLE-001) is untouched by any of this —
# proven by reusing those exact fixtures unmodified. BRANCH below is new-style: it must
# establish a task/<TASK-ID>-<slug> branch from the canonical branch's exact tip before
# baseline is even possible, and every mutating phase after that must run on that exact branch.
branch_test() {
  tmp=$(mktemp -d /tmp/deterministic-branch.XXXXXX); tmp2=$(mktemp -d /tmp/deterministic-branch-dirty.XXXXXX); trap 'rm -rf "$tmp" "$tmp2"' EXIT
  mkdir -p "$tmp/.agents/runs/BRANCH/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  printf 'BRANCH\n' > "$tmp/.agents/ACTIVE_RUN"; printf '# Task\n' > "$tmp/.agents/runs/BRANCH/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/BRANCH/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/BRANCH/PLAN.md"
  printf '%s\n' 'task:' '  id: BRANCH' 'repository:' '  base_sha: PENDING' '  canonical_branch: PENDING' '  task_branch: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/BRANCH-sample-feature.md' '  revision: PENDING' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/BRANCH/RUN.yaml"
  printf '# review\n' > "$tmp/.agents/runs/BRANCH/review/code-review.md"; printf '# verification\n' > "$tmp/.agents/runs/BRANCH/review/verification.md"; printf '# result\n' > "$tmp/.agents/runs/BRANCH/RESULT.md"
  (cd "$tmp"; git init -q -b main; git config user.email branch@example.invalid; git config user.name fixture
    : > authorized.txt; printf '# sample feature\n' > tasks/BRANCH-sample-feature.md; git add -- .agents scripts tasks authorized.txt; git commit -qm baseline
    canonical_sha=$(git rev-parse HEAD)
    if ./scripts/agent.sh baseline BRANCH; then exit 1; fi
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh branch BRANCH; then exit 1; fi
    ./scripts/agent.sh branch BRANCH
    [ "$(git branch --show-current)" = task/BRANCH-sample-feature ]
    [ "$(git rev-parse task/BRANCH-sample-feature)" = "$canonical_sha" ]
    ./scripts/agent.sh branch BRANCH
    [ "$(git branch --show-current)" = task/BRANCH-sample-feature ]
    [ "$(git branch --list 'task/BRANCH-*' | wc -l | tr -d ' ')" = 1 ]
    ./scripts/agent.sh baseline BRANCH; printf 'discovered\n' >> .agents/runs/BRANCH/EVIDENCE.md; printf 'planned\n' >> .agents/runs/BRANCH/PLAN.md; ./scripts/agent.sh freeze BRANCH
    ./scripts/agent.sh handoff BRANCH IMPLEMENTING
    AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope BRANCH; AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff BRANCH IMPLEMENTING
    git checkout -q main
    if ./scripts/agent.sh handoff BRANCH VERIFIED; then exit 1; fi
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope BRANCH; then exit 1; fi
    git checkout -q --detach "$canonical_sha"
    if ./scripts/agent.sh handoff BRANCH VERIFIED; then exit 1; fi
    git checkout -q -b random-feature
    if ./scripts/agent.sh handoff BRANCH VERIFIED; then exit 1; fi
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope BRANCH; then exit 1; fi
    git checkout -q main; git branch task/OTHER-unrelated "$canonical_sha"; git checkout -q task/OTHER-unrelated
    if ./scripts/agent.sh handoff BRANCH VERIFIED; then exit 1; fi
    git checkout -q main; git branch -D task/OTHER-unrelated random-feature > /dev/null
    git checkout -q task/BRANCH-sample-feature
    cp .agents/runs/BRANCH/RUN.yaml tampered.original
    sed 's#task_branch: "task/BRANCH-sample-feature"#task_branch: "task/BRANCH-tampered"#' tampered.original > .agents/runs/BRANCH/RUN.yaml
    if ./scripts/agent.sh handoff BRANCH VERIFIED; then exit 1; fi
    mv tampered.original .agents/runs/BRANCH/RUN.yaml
    ./scripts/agent.sh handoff BRANCH VERIFIED; ./scripts/agent.sh handoff BRANCH REVIEWED; ./scripts/agent.sh handoff BRANCH CODE_DONE; ./scripts/agent.sh delivery-check BRANCH
    git checkout -q main; if ./scripts/agent.sh branch BRANCH; then exit 1; fi; git checkout -q task/BRANCH-sample-feature)
  mkdir -p "$tmp2/.agents/runs/CONFLICT/review" "$tmp2/scripts" "$tmp2/.agents/modes"
  cp "$root/scripts/agent.sh" "$tmp2/scripts/"; cp "$root/.agents/config.yaml" "$tmp2/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp2/.agents/modes/"
  printf '# Task\n' > "$tmp2/.agents/runs/CONFLICT/TASK.md"; printf '# Evidence\n' > "$tmp2/.agents/runs/CONFLICT/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: tracked.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp2/.agents/runs/CONFLICT/PLAN.md"
  printf '%s\n' 'task:' '  id: CONFLICT' 'repository:' '  base_sha: PENDING' '  canonical_branch: PENDING' '  task_branch: PENDING' 'task_source:' '  type: none' '  revision: not_applicable' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp2/.agents/runs/CONFLICT/RUN.yaml"
  printf '# review\n' > "$tmp2/.agents/runs/CONFLICT/review/code-review.md"; printf '# verification\n' > "$tmp2/.agents/runs/CONFLICT/review/verification.md"; printf '# result\n' > "$tmp2/.agents/runs/CONFLICT/RESULT.md"
  (cd "$tmp2"; git init -q -b main; git config user.email conflict@example.invalid; git config user.name fixture
    printf 'v1\n' > tracked.txt; git add -- .agents scripts tracked.txt; git commit -qm base
    base_sha=$(git rev-parse HEAD)
    git branch task/CONFLICT-run "$base_sha"
    printf 'v2\n' > tracked.txt; git add tracked.txt; git commit -qm advance
    if ./scripts/agent.sh branch CONFLICT; then exit 1; fi
    [ "$(git rev-parse task/CONFLICT-run)" = "$base_sha" ]
    [ "$(git branch --show-current)" = main ]
    printf 'uncommitted\n' >> tracked.txt
    if git checkout task/CONFLICT-run 2>/dev/null; then exit 1; fi
    [ "$(git branch --show-current)" = main ]; grep -Fxq uncommitted tracked.txt)
  echo 'branch policy tests passed'
}

valid_role
command=${1:-}; case "$command" in
  role) printf 'role=%s\n' "$execution_role" ;;
  status) id=$(active_run); echo "active_task=${id:-none}"; echo "implementation_allowed=$( [ -n "$id" ] && echo true || echo false )"; effective "$id" ;;
  effective) effective "${2:-}" ;;
  baseline) require_full_lifecycle; baseline "${2:?usage: $0 baseline <TASK-ID>}" ;;
  branch) require_full_lifecycle; branch_setup "${2:?usage: $0 branch <TASK-ID>}" ;;
  freeze) require_full_lifecycle; freeze "${2:?usage: $0 freeze <TASK-ID>}" ;;
  refreeze) require_full_lifecycle; freeze "${2:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" refreeze "${3:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze <TASK-ID>}" ;;
  verify-scope) verify_scope "${2:?usage: $0 verify-scope <TASK-ID>}" ;;
  freshness) verify_freshness "${2:?usage: $0 freshness <TASK-ID>}" ;;
  handoff) [ "$execution_role" = full_lifecycle ] || [ "${3:-}" = IMPLEMENTING ] || fail "handoff phase denied for implementation_worker"; record_handoff "${2:?usage: $0 handoff <TASK-ID> <PHASE>}" "${3:?usage: $0 handoff <TASK-ID> <PHASE>}" ;;
  verify-handoff) verify_handoff "${2:?usage: $0 verify-handoff <TASK-ID>}" ;;
  delivery-check) require_full_lifecycle; delivery_check "${2:?usage: $0 delivery-check <TASK-ID>}" ;;
  worker-evidence) record_worker_evidence "${2:?usage: $0 worker-evidence <TASK-ID> <RED|GREEN|REFACTOR|FIX> <pass|fail>}" "${3:?usage: $0 worker-evidence <TASK-ID> <PHASE> <RESULT>}" "${4:?usage: $0 worker-evidence <TASK-ID> <PHASE> <RESULT>}" ;;
  verify-worker-evidence) verify_worker_evidence "${2:?usage: $0 verify-worker-evidence <TASK-ID>}" ;;
  knowledge-done) knowledge_done "${2:?usage: $0 knowledge-done <TASK-ID> [not_applicable]}" "${3:-KNOWLEDGE_DONE}" ;;
  publish-completion-report) publish_completion_report "${2:?usage: $0 publish-completion-report <TASK-ID> [ADAPTER]}" "${3:-markdown}" ;;
  verify-completion-report) verify_completion_report "${2:?usage: $0 verify-completion-report <TASK-ID>}" ;;
  validate) id=${2:?usage: $0 validate <TASK-ID>}; require_run "$id"; dir=$(run_dir "$id"); for f in TASK.md EVIDENCE.md PLAN.md RUN.yaml review/code-review.md review/verification.md RESULT.md; do [ -f "$dir/$f" ] || fail "missing required artifact: $f"; done; if section_key_present "$dir" completion_report required; then [ -f "$dir/COMPLETION_REPORT.md" ] || fail "missing required artifact: COMPLETION_REPORT.md"; fi; validate_control_artifacts "$id"; scope_mappings "$dir/PLAN.md" >/dev/null; status=$(baseline_status "$dir"); if [ "$status" = captured ]; then validate_captured_baseline "$dir"; else historical_reference "$id" || fail "baseline missing or pending: $id"; fi; verify_freshness "$id"; verify_handoff "$id"; echo "run validated: $id" ;;
  test) require_full_lifecycle; fixture_test; branch_test; policy_test; standalone_test ;;
  role-test) require_full_lifecycle; role_test ;;
  *) echo "usage: $0 {role|status|effective|baseline|branch|freeze|refreeze|verify-freeze|freshness|handoff|verify-handoff|delivery-check|worker-evidence|verify-worker-evidence|knowledge-done|publish-completion-report|verify-completion-report|validate|test|role-test} [TASK-ID]" >&2; exit 2 ;;
esac

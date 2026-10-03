#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=$root/.agents/config.yaml
execution_role=${AGENT_ROLE:-full_lifecycle}
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
run_dir() { printf '%s/.agents/runs/%s\n' "$root" "$1"; }
config_value() { sed -n "s/^$1: *//p" "$2" | head -n 1 | tr -d '"'; }
fail() { echo "$*" >&2; return 1; }
valid_role() { case "$execution_role" in full_lifecycle|implementation_worker|independent_reviewer|independent_qa|independent_verifier|explorer|architect) ;; *) fail "invalid execution role: $execution_role";; esac; }
require_full_lifecycle() { [ "$execution_role" = full_lifecycle ] || fail "command denied for implementation_worker"; }

valid_task_id() { case "$1" in *[!A-Za-z0-9_-]*|'') return 1;; esac; }

# --- Workflow events (optional observer) -------------------------------------
# workflow_event <ID> --event E --stage S --status T [--gate G --attempt N --loop N --findings-open N --fingerprint H]
# No-op unless AGENT_WORKFLOW_EVENTS_URL is set. Fail-open: always returns 0. The event contract is the header of scripts/oversight/event.sh.
# The role on an event is the invoking AGENT_ROLE. A call site MUST NOT pass --role to claim another role.
workflow_event() {
  [ -n "${AGENT_WORKFLOW_EVENTS_URL:-}" ] || return 0
  we_id=$1; shift
  we_topo=$(resolve_topology "$(run_dir "$we_id")" 2>/dev/null) || we_topo=''
  sh "$root/scripts/oversight/event.sh" --root "$root" --task "$we_id" --role "$execution_role" --topology "$we_topo" "$@" >/dev/null 2>&1 || true
  return 0
}
ev_result() { if [ "$1" = pass ] || [ "$1" = success ]; then echo passed; else echo failed; fi; }

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
      if (value != "" && (section ~ /^(task|baseline|evidence|plan|context|wiki|memory|self_learning|orchestration|review|qa|verification)$/ || key ~ /^(enabled|required|read|write|write_during_code_transaction|max_implementation_workers|recursive_delegation|max_bounded_fix_attempts|swarm|independent|independent_verifier|required_before_implementation|strategy|control_plane|default|index_first|expand_only_if_needed|load_unrelated_runs|include_session_history_in_review)$/)) print section "." key "=" value
    }
  ' "$policy"
}

run_state() { sed -n 's/^[[:space:]]*state: *//p' "$1/RUN.yaml" | head -1 | tr -d '"'; }
# FAILED and BLOCKED are terminal: no lifecycle command moves such a run (see terminate_run).
require_open_run() { case "$(run_state "$(run_dir "$1")")" in FAILED|BLOCKED) fail "run $1 is $(run_state "$(run_dir "$1")") (terminal); it accepts no further lifecycle commands" ;; esac; }
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

# Deterministic per-task Git branch isolation. A RUN.yaml that has the repository.task_branch
# key (every run created from the template) must have it resolved (not PENDING) with the
# working tree actually on it before any mutating lifecycle phase proceeds. Only the isolated
# fixture suites below omit the key, to test the other layers on their own.
enforce_task_branch() {
  id=$1; dir=$(run_dir "$id")
  section_key_present "$dir" repository task_branch || return 0
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

# --- Pipeline: task classification selects the lifecycle -------------------
#
# `.agents/config.yaml`'s `pipelines:` table maps a classification
# (TRIVIAL|STANDARD|COMPLEX|CRITICAL) to what that task class requires: whether
# EVIDENCE.md is produced and frozen, whether QA_PLAN.md is produced and frozen
# (which also makes the QA gate required), whether PLAN.md carries an
# `## Architecture` section, and whether the REVIEW gate is required
# (`yes`, `no`, or `optional` — decided per run by `classify`). The VERIFY gate
# is required for every class. `agent.sh classify` records the choice in
# RUN.yaml's `pipeline:` block; `freeze` records it as `freeze.pipeline`, so
# changing it after freeze fails `verify-freeze` until an amendment + refreeze.
# Everything downstream (frozen artifacts, allowed run files, required gates,
# completion-report headings) is derived from these functions and nothing else.
pipeline_value() { # CLASS KEY
  awk -v c="$1" -v k="$2" '
    /^pipelines:$/ { inside=1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && /^  [A-Z]+:$/ { cur=$1; sub(/:$/, "", cur); next }
    inside && cur == c && $0 ~ "^    " k ":" { v=$0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/"/, "", v); print v; exit }
  ' "$config"
}
pipeline_class_valid() { case "$1" in TRIVIAL|STANDARD|COMPLEX|CRITICAL) return 0 ;; *) return 1 ;; esac; }
pipeline_class() { section_value "$(run_dir "$1")" pipeline classification; }
pipeline_declared() { gates_enforced "$1" && section_key_present "$(run_dir "$1")" pipeline classification; }
# What the run's pipeline requires for <evidence|qa|architect>. A run without a valid
# classification (not yet classified, or a fixture without gates) needs EVIDENCE.md only.
pipeline_needs() { # ID KEY
  pn_class=$(pipeline_class "$1")
  if pipeline_declared "$1" && pipeline_class_valid "$pn_class"; then pipeline_value "$pn_class" "$2"; return 0; fi
  if [ "$2" = evidence ]; then echo yes; else echo no; fi
}
pipeline_review() {
  pr_class=$(pipeline_class "$1"); pr_value=$(pipeline_value "$pr_class" review)
  case "$pr_value" in
    yes|no) printf '%s\n' "$pr_value" ;;
    optional) if [ "$(section_value "$(run_dir "$1")" pipeline review)" = yes ]; then echo yes; else echo no; fi ;;
    *) echo no ;;
  esac
}
# The gates the run's pipeline requires before CODE_DONE, one per line (none until classified).
pipeline_gates() {
  pipeline_declared "$1" && pipeline_class_valid "$(pipeline_class "$1")" || return 0
  if [ "$(pipeline_review "$1")" = yes ]; then echo REVIEW; fi
  if [ "$(pipeline_needs "$1" qa)" = yes ]; then echo QA; fi
  echo VERIFY
}
pipeline_signature() {
  if pipeline_declared "$1" && pipeline_class_valid "$(pipeline_class "$1")"; then printf '%s:review=%s\n' "$(pipeline_class "$1")" "$(pipeline_review "$1")"; fi
}
# Freeze-time artifact contract: required artifacts exist, artifacts the pipeline does not
# require do not (no placeholders), and the class-specific plan rules hold.
pipeline_check() {
  id=$1; dir=$(run_dir "$id")
  if gates_enforced "$id"; then
    pipeline_declared "$id" || fail "RUN.yaml has no pipeline block (create the run from .agents/templates/RUN.yaml)"
    pipeline_class_valid "$(pipeline_class "$id")" || fail "run $id is not classified: run '$0 classify $id <TRIVIAL|STANDARD|COMPLEX|CRITICAL>' first"
  fi
  class=$(pipeline_class "$id")
  for pc in "evidence EVIDENCE.md" "qa QA_PLAN.md"; do
    set -- $pc
    if [ "$(pipeline_needs "$id" "$1")" = yes ]; then [ -f "$dir/$2" ] || fail "missing $2 (required by the ${class:-default} pipeline)"
    else [ ! -e "$dir/$2" ] || fail "$2 is not part of the ${class:-default} pipeline; remove it (no artifacts without a consumer)"; fi
  done
  if [ "$(pipeline_needs "$id" architect)" = yes ]; then
    grep -q '^## Architecture' "$dir/PLAN.md" || fail "the $class pipeline requires an '## Architecture' section in PLAN.md (the Architect's contribution)"
  fi
  pc_max=$(pipeline_value "$class" max_scope_paths)
  if [ -n "$pc_max" ]; then
    pc_n=$(scope_mappings "$dir/PLAN.md" | wc -l | tr -d ' ')
    [ "$pc_n" -le "$pc_max" ] || fail "the $class pipeline allows at most $pc_max scope paths; this plan has $pc_n — reclassify"
  fi
}
# What the run's pipeline requires — the one place a role session asks "what is expected of this run".
pipeline_show() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  pipeline_declared "$id" || fail "run $id has no pipeline block"
  class=$(pipeline_class "$id"); pipeline_class_valid "$class" || fail "run $id is not classified yet"
  printf 'classification=%s\nreview=%s\nevidence=%s\nqa_plan=%s\narchitect=%s\nmax_explorers=%s\ngates=%s\n' "$class" "$(pipeline_review "$id")" "$(pipeline_needs "$id" evidence)" "$(pipeline_needs "$id" qa)" "$(pipeline_needs "$id" architect)" "$(pipeline_value "$class" max_explorers)" "$(pipeline_gates "$id" | tr '\n' ' ' | sed 's/ $//')"
}
# Records the task classification. Allowed at any point before CODE_DONE; after freeze the
# change voids the freeze (freeze.pipeline) until an amendment and refreeze, and every use is
# ledgered. `review` is only meaningful where the pipeline says `review: optional`.
classify() {
  id=$1 class=$2 opt=${3:-}; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  gates_enforced "$id" || fail "classify requires the lifecycle_gates policy"
  pipeline_declared "$id" || fail "RUN.yaml has no pipeline block (create the run from .agents/templates/RUN.yaml)"
  require_open_run "$id"
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "cannot reclassify a completed run: $id"
  pipeline_class_valid "$class" || fail "invalid classification: $class (want TRIVIAL|STANDARD|COMPLEX|CRITICAL)"
  enforce_task_branch "$id"; verify_seal "$id"
  configured=$(pipeline_value "$class" review)
  case "$configured" in
    yes|no) [ -z "$opt" ] || fail "the $class pipeline fixes review=$configured; the 'review' option exists only where a pipeline says optional"; review=$configured ;;
    optional) case "$opt" in '') review=no ;; review) review=yes ;; *) fail "unknown option: $opt (want: review)" ;; esac ;;
    *) fail "no pipelines.$class entry in .agents/config.yaml" ;;
  esac
  set_run_value "$id" pipeline classification "$class"; set_run_value "$id" pipeline review "$review"
  ledger_append "$id" classify "$(section_value "$dir" handoff state)" "$(section_value "$dir" handoff state)" "$class review=$review"
  workflow_event "$id" --event stage --stage discover --status started
  echo "classified: $id $class (gates: $(pipeline_gates "$id" | tr '\n' ' '))"
}

# ---------------------------------------------------------------------------
# Execution policy. `decide` is the only caller of scripts/exec-policy.sh (the one
# resolver) and persists exactly one decision per attempt under the run's
# decisions/ directory; scripts/worker-run.sh consumes that decision and re-decides
# nothing. The resolver is pure: the class comes from this run's classification,
# the retry bound is verification.max_bounded_fix_attempts (the one retry system),
# and scope evidence is the frozen PLAN.md's paths. See .agents/WORKFLOW.md
# "Execution policy".
# ---------------------------------------------------------------------------
decision_field() { sed -n "s/^$2=//p" "$1" | head -1; }
# The newest decision for a phase within the current amendment epoch (an amendment
# starts a fresh fix budget, so it starts fresh attempt counting too).
latest_decision() { # ID PHASE
  ld_dir=$(run_dir "$1")/decisions; ld_epoch=$(ls -1 "$(run_dir "$1")/amendments" 2>/dev/null | wc -l | tr -d ' ')
  ls -1 "$ld_dir" 2>/dev/null | grep -E "^$ld_epoch-$2-[0-9]+\.decision\$" | sort -t- -k3,3n | tail -1 | sed "s#^#$ld_dir/#"
}
decide() { # ID PHASE [--failure CODE] [--model M] [--effort E] [--delegation N] [--context-bytes B]
  id=$1 phase=$2; shift 2; require_run "$id"; require_open_run "$id"; dir=$(run_dir "$id")
  case "$phase" in RED|GREEN|REFACTOR|FIX) ;; *) fail "invalid phase: $phase (want RED|GREEN|REFACTOR|FIX)" ;; esac
  class=$(pipeline_class "$id"); pipeline_class_valid "$class" || fail "run $id is not classified: the execution policy is derived from its task class"
  topo=$(resolve_topology "$dir"); has_failure=no
  for d_arg in "$@"; do [ "$d_arg" = --failure ] && has_failure=yes; done
  d_last=$(latest_decision "$id" "$phase"); attempt=1; prev='0 0 0 0'; d_seq=1
  if [ -n "$d_last" ]; then
    d_seq=$(( $(basename "$d_last" .decision | awk -F- '{print $3}') + 1 ))
    if [ "$(decision_field "$d_last" outcome)" != success ]; then
      attempt=$(( $(decision_field "$d_last" attempt) + 1 ))
      prev="$(decision_field "$d_last" esc_model) $(decision_field "$d_last" esc_effort) $(decision_field "$d_last" esc_context) $(decision_field "$d_last" esc_events)"
      # A re-run with no stated failure is a same-capability retry, recorded as such.
      [ "$has_failure" = yes ] || set -- "$@" --failure TRANSIENT
    fi
  fi
  d_epoch=$(ls -1 "$dir/amendments" 2>/dev/null | wc -l | tr -d ' '); mkdir -p "$dir/decisions"
  d_out="$dir/decisions/$d_epoch-$phase-$d_seq.decision"; d_tmp="$d_out.tmp"
  { [ -f "$dir/PLAN.md" ] && scope_mappings "$dir/PLAN.md" | cut -d '|' -f1 || true; } | \
    "$root/scripts/exec-policy.sh" resolve --class "$class" --topology "$topo" --review "$(pipeline_review "$id")" \
      --attempt "$attempt" --retry-limit "$(max_fix_attempts "$id")" --prev "$prev" "$@" > "$d_tmp" || { d_rc=$?; rm -f "$d_tmp"; return "$d_rc"; }
  printf 'phase=%s\nseq=%s\n' "$phase" "$d_seq" >> "$d_tmp"; mv "$d_tmp" "$d_out"
  workflow_event "$id" --event attempt --stage implement --status started --attempt "$attempt"
  cat "$d_out"; echo "decision_file=${d_out#$root/}"
}
# Minimal local execution evidence appended to a decision after the attempt:
# outcome, and any measured k=v (exit_status, duration_s, context_bytes_used, ...).
decision_outcome() { # ID PHASE success|failure [k=v ...]
  id=$1 phase=$2 outcome=$3; shift 3; require_run "$id"
  case "$outcome" in success|failure) ;; *) fail "outcome must be success|failure" ;; esac
  d_last=$(latest_decision "$id" "$phase"); [ -n "$d_last" ] || fail "no decision recorded for $id $phase"
  [ -z "$(decision_field "$d_last" outcome)" ] || fail "outcome already recorded for ${d_last#$root/}"
  printf 'outcome=%s\n' "$outcome" >> "$d_last"
  for d_kv in "$@"; do case "$d_kv" in [a-z_]*=*) printf '%s\n' "$d_kv" >> "$d_last" ;; *) fail "bad metric: $d_kv" ;; esac; done
  workflow_event "$id" --event attempt --stage implement --status "$(ev_result "$outcome")" --attempt "$(decision_field "$d_last" attempt)"
}

# Freezes exactly the artifacts the run's pipeline requires; an artifact the pipeline does
# not require is recorded as `not_required`, never hashed.
replace_hashes() {
  dir=$1 target=$2; id=$(basename "$dir"); mode=$(sed -n 's/^[[:space:]]*mode: *//p' "$dir/RUN.yaml" | head -1); [ -n "$mode" ] || mode=$(config_value default_mode "$config")
  task_hash=$(hash_file "$dir/TASK.md"); plan_hash=$(hash_file "$dir/PLAN.md"); policy_hash=$(hash_file "$root/.agents/modes/$mode.yaml")
  evidence_hash=not_required; [ "$(pipeline_needs "$id" evidence)" = yes ] && evidence_hash=$(hash_file "$dir/EVIDENCE.md")
  qa_plan_hash=not_required; [ "$(pipeline_needs "$id" qa)" = yes ] && qa_plan_hash=$(hash_file "$dir/QA_PLAN.md")
  awk -v a="$task_hash" -v b="$evidence_hash" -v c="$plan_hash" -v d="$policy_hash" -v e="$qa_plan_hash" -v f="$(pipeline_signature "$id")" '
    /^[[:space:]]*task_sha256:/ { print "  task_sha256: \"" a "\""; next }
    /^[[:space:]]*evidence_sha256:/ { print "  evidence_sha256: \"" b "\""; next }
    /^[[:space:]]*plan_sha256:/ { print "  plan_sha256: \"" c "\""; next }
    /^[[:space:]]*qa_plan_sha256:/ { print "  qa_plan_sha256: \"" e "\""; next }
    /^[[:space:]]*policy_sha256:/ { print "  policy_sha256: \"" d "\""; next }
    /^[[:space:]]+pipeline:/ && f != "" { print "  pipeline: \"" f "\""; next }
    { print }
  ' "$dir/RUN.yaml" > "$target"
}
# The frozen task contract. A run with a local Markdown task source records and
# checks a *projection* of it rather than the whole file: the value of every
# `**Status:**` line and the single completion-report block the markdown
# adapter appends (its `## Completion Report` heading through the END marker) are
# lifecycle bookkeeping and are projected out; trailing blank lines are ignored;
# everything else is the contract. The recorded revision is written by
# `freeze`/`refreeze` only (refreeze needs an amendment) — never by publish — and
# the task source's location changes only through `task-source-relocate`.
local_task_source_run() { [ "$(section_value "$(run_dir "$1")" task_source type)" = local_markdown ]; }
task_source_contract_hash() {
  awk -v id="$1" '
    { line[NR] = $0 }
    END {
      begin = "<!-- COMPLETION-REPORT:BEGIN:" id " -->"; endm = "<!-- COMPLETION-REPORT:END:" id " -->"
      n = 0; stripped = 0
      for (i = 1; i <= NR; i++) {
        if (!stripped && line[i] == "## Completion Report") {
          j = i + 1
          while (j <= NR && line[j] ~ /^[[:space:]]*$/) j++
          if (j <= NR && line[j] == begin) {
            for (k = j + 1; k <= NR && line[k] != endm; k++) { }
            if (k <= NR) { i = k; stripped = 1; continue }
          }
        }
        out = line[i]
        if (out ~ /^\*\*Status:\*\*/) out = "**Status:**"
        kept[++n] = out
      }
      while (n > 0 && kept[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print kept[i]
    }
  ' "$2" | shasum -a 256 | awk '{print $1}'
}
set_task_source_revision() {
  dir=$1 type=$(section_value "$dir" task_source type)
  case "$type" in
    local_markdown) source=$(local_task_source "$dir") || return 1; replace_section_value "$dir" task_source revision "$(task_source_contract_hash "$(basename "$dir")" "$source")" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    none) [ "$(section_value "$dir" task_source revision)" = not_applicable ] || fail "task source none requires revision: not_applicable" ;;
    *) fail "task source adapter unavailable: ${type:-missing}" ;;
  esac
}
# A task source kept in a lifecycle folder (backlog/, todo/, in-progress/, done/)
# declares that state in its own `**Status:**` line. The value is bookkeeping (it is
# excluded from the frozen contract), but the control plane refuses to proceed while
# it contradicts the folder; `task-source-status` synchronizes it.
lifecycle_folder_status() {
  case "$(basename "$(dirname "$1")")" in
    backlog) echo backlog ;; todo) echo todo ;; in-progress) echo in-progress ;; done) echo done ;;
  esac
}
declared_task_status() { sed -n 's/^\*\*Status:\*\*[[:space:]]*//p' "$1" | head -1 | sed 's/[[:space:]]*$//'; }
verify_task_source_status() {
  id=$1; dir=$(run_dir "$id"); local_task_source_run "$id" || return 0
  path=$(section_value "$dir" task_source path); want=$(lifecycle_folder_status "$path")
  [ -n "$want" ] && [ -f "$root/$path" ] || return 0
  have=$(declared_task_status "$root/$path"); [ -n "$have" ] || return 0
  [ "$have" = "$want" ] || fail "task source status mismatch: $path is under $want/ but declares **Status:** $have; run '$0 task-source-status $id' (the Status value is bookkeeping and needs no re-baseline)"
}
# A change to the recorded task source that leaves its frozen contract byte-for-byte
# intact (only the Status value or the completion-report block differ) is bookkeeping.
task_source_bookkeeping_only() {
  id=$1 path=$2; dir=$(run_dir "$id"); local_task_source_run "$id" || return 1
  [ "$path" = "$(section_value "$dir" task_source path)" ] || return 1
  revision=$(section_value "$dir" task_source revision); case "$revision" in ''|PENDING|not_applicable) return 1 ;; esac
  [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || return 1
  [ "$revision" = "$(task_source_contract_hash "$id" "$root/$path")" ]
}
local_task_source() {
  dir=$1 path=$(section_value "$dir" task_source path)
  case "$path" in ''|/*|*'..'*|*'//'*) fail "invalid local Markdown task source path";; esac
  source=$root/$path
  [ ! -L "$source" ] || fail "task source must not be a symlink: $path"
  [ -f "$source" ] || fail "task source missing or non-regular: $path$(task_source_moved_hint "$dir")"
  printf '%s\n' "$source"
}
task_source_moved_hint() {
  local_task_source_run "$(basename "$1")" && printf " (if the task file was moved, record it with 'agent.sh task-source-relocate %s <NEW-PATH>')" "$(basename "$1")"
  return 0
}
verify_freshness() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  verify_freeze "$id"
  base=$(repository_base_sha "$dir"); head=$(git -C "$root" rev-parse HEAD)
  [ "$base" = "$head" ] || fail "stale plan: repository.base_sha changed ($base -> $head); amendment and refreeze required"
  type=$(section_value "$dir" task_source type); revision=$(section_value "$dir" task_source revision)
  case "$type:$revision" in
    local_markdown:*)
      source=$(local_task_source "$dir") || return 1
      verify_task_source_status "$id"
      [ "$revision" = "$(task_source_contract_hash "$id" "$source")" ] || fail "stale plan: the frozen task contract changed (the Status value and the published completion-report block are bookkeeping and excluded; nothing else may change); amendment and refreeze required" ;;
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
  for pair in "task TASK.md yes" "evidence EVIDENCE.md $(pipeline_needs "$id" evidence)" "plan PLAN.md yes" "qa_plan QA_PLAN.md $(pipeline_needs "$id" qa)"; do
    set -- $pair; stored=$(sed -n "s/^[[:space:]]*$1_sha256: *[\"]*\([^\" ]*\).*/\1/p" "$run" | head -1)
    if [ "$3" = yes ]; then actual=$(hash_file "$dir/$2"); else actual=not_required; [ -n "$stored" ] || continue; [ ! -e "$dir/$2" ] || fail "$2 is not part of this run's pipeline; remove it"; fi
    [ -n "$stored" ] && [ "$stored" = "$actual" ] || fail "freeze mismatch: $1"
  done
  # The frozen pipeline is the frozen classification: changing it after freeze needs an amendment and a refreeze.
  if gates_enforced "$id"; then
    [ "$(section_value "$dir" freeze pipeline)" = "$(pipeline_signature "$id")" ] || fail "freeze mismatch: pipeline (the classification changed or was removed after freeze; an amendment and refreeze are required)"
  fi
  stored=$(sed -n 's/^[[:space:]]*policy_sha256: *[\"]*\([^\" ]*\).*/\1/p' "$run" | head -1); actual=$(hash_file "$root/.agents/modes/$mode.yaml")
  [ -n "$stored" ] && [ "$stored" = "$actual" ] || fail "freeze mismatch: policy"
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

# The Transaction B (knowledge transaction) scope boundary — see
# .agents/config.yaml's `knowledge_scope_root`. Deliberately a single
# explicit directory-prefix allowlist, never "anything verify_scope doesn't
# otherwise recognize" — an unset/empty root means nothing is in knowledge
# scope (fails closed to the pre-existing, stricter behavior), not "allow
# everything".
knowledge_scope_root() { config_value knowledge_scope_root "$config"; }
in_knowledge_scope() {
  # NOTE: must not name this local var "root" — this script has no `local`
  # (POSIX sh) and the top-level `root` (repository root path) is used
  # everywhere via plain assignment; shadowing it here previously corrupted
  # every subsequent path computation for the rest of the process.
  kroot=$(knowledge_scope_root); [ -n "$kroot" ] || return 1
  case "$1" in "$kroot"*) return 0 ;; *) return 1 ;; esac
}
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
  enforce_task_branch "$id"; require_open_run "$id"
  case "$phase" in IMPLEMENTING|IMPLEMENTED|CODE_DONE|DONE) ;; *) fail "invalid handoff phase";; esac
  # Only the DONE transition may legitimately see knowledge-scope (Transaction
  # B) diffs — every earlier phase keeps strict application-only scope
  # checking, so a wiki write attempted during DISCOVER/PLAN/IMPLEMENT/
  # VERIFY/REVIEW is still rejected exactly as before this existed.
  allow_knowledge=0; [ "$phase" = DONE ] && allow_knowledge=1
  verify_freshness "$id"; verify_scope "$id" "$allow_knowledge"
  # A hand edit of RUN.yaml lifecycle fields (a manual rewind of the lifecycle state) is
  # detected before any further transition is layered on top of it.
  verify_seal "$id"
  patch=$(task_patch_fingerprint "$id")
  current=$(section_value "$dir" handoff state)
  case "$phase" in
    IMPLEMENTING)
      case "$current" in
        PLANNED|IMPLEMENTING) ;;
        # Returning to IMPLEMENTING from IMPLEMENTED exists only for a
        # lifecycle_gates run with an open gate finding, and only for one
        # bounded fix (see reopen_for_fix); every other run has no way back.
        IMPLEMENTED) gates_enforced "$id" || fail "illegal handoff transition: $current -> $phase"
          [ "$execution_role" = full_lifecycle ] || fail "only the Orchestrator may reopen implementation after a gate finding (diagnosis comes first)"
          reopen_for_fix "$id" "$patch" ;;
        *) fail "illegal handoff transition: $current -> $phase";;
      esac ;;
    IMPLEMENTED)
      case "$current" in
        IMPLEMENTING|IMPLEMENTED) ;;
        *) fail "illegal handoff transition: $current -> $phase" ;;
      esac
      # Lifecycle advancement out of IMPLEMENT must be backed by auditable
      # implementation_worker evidence (or a validated TDD exemption) for
      # every non-exempt behavior-changing scope path — this is the concrete
      # mechanism preventing a full_lifecycle session from silently
      # implementing application code itself and then advancing the state
      # machine as though delegation occurred. No-op for a run without the
      # worker_evidence policy key (see policy_enforced).
      verify_worker_evidence "$id"
      # lifecycle_gates runs additionally prove *who* changed the tree
      # (orchestrated: only the implementation_worker) and that a fix stayed
      # inside its finding's fix_scope. No-ops for every other run.
      verify_mutation_ownership "$id" 1
      verify_fix_bound "$id"
      replace_section_value "$dir" handoff implemented_patch_sha256 "$patch" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
      replace_section_value "$dir" handoff code_done_patch_sha256 PENDING "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    CODE_DONE)
      case "$current" in IMPLEMENTED|CODE_DONE) ;; *) fail "illegal handoff transition: $current -> $phase";; esac
      [ "$(section_value "$dir" handoff implemented_patch_sha256)" = "$patch" ] || fail "CODE_DONE blocked: the application tree changed since IMPLEMENTED"
      # The quality gate: every gate the run's pipeline requires must hold a current pass for this exact tree.
      if gates_enforced "$id"; then
        verify_mutation_ownership "$id"
        verify_required_gates "$id" "$patch" "CODE_DONE blocked"
      fi
      replace_section_value "$dir" handoff code_done_patch_sha256 "$patch" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml" ;;
    DONE)
      case "$current" in CODE_DONE|DONE) ;; *) fail "illegal handoff transition: $current -> $phase";; esac
      # Application scope integrity: task_patch_fingerprint/task_owned_paths
      # (unchanged by this fix) never include a knowledge-scope path in the
      # first place, so this check is exactly as strict as it always was —
      # a wiki write cannot move or hide an application-scope violation.
      [ "$(section_value "$dir" handoff code_done_patch_sha256)" = "$patch" ] || fail "DONE blocked: CODE_DONE stale or missing"
      # Knowledge transaction integrity: the Transaction B counterpart to the
      # application-scope check above — see verify_knowledge_scope.
      verify_knowledge_scope "$id"
      verify_lifecycle_gates "$id"
      section_key_present "$dir" completion_report required && {
        ks=$(section_value "$dir" execution knowledge_state)
        case "$ks" in KNOWLEDGE_DONE|not_applicable) ;; *) fail "DONE blocked: knowledge transaction not recorded complete (see 'agent.sh knowledge-done')" ;; esac
        verify_completion_report "$id"
      } ;;
  esac
  tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" handoff state "$phase" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  if [ "$phase" = CODE_DONE ]; then replace_section_value "$dir" execution state CODE_DONE "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"; fi
  if gates_enforced "$id"; then ledger_append "$id" "handoff:$phase" "$current" "$phase" ""; fi
  case "$phase" in
    IMPLEMENTING) workflow_event "$id" --event stage --stage implement --status started ;;
    IMPLEMENTED) workflow_event "$id" --event stage --stage implement --status completed --fingerprint "$patch" ;;
    CODE_DONE) workflow_event "$id" --event stage --stage code_done --status passed --fingerprint "$patch" ;;
    DONE) workflow_event "$id" --event outcome --stage done --status completed --fingerprint "$patch" ;;
  esac
  echo "handoff recorded: $id $phase"
}
# $2 (default: 0/strict) — forwarded to verify_scope; see verify_scope's own
# doc comment. Only delivery_check passes 1 (post-DONE delivery readiness
# must not re-reject a knowledge transaction DONE already accepted); the
# `verify-handoff` CLI command and every other caller keep strict/0.
verify_handoff() {
  id=$1 allow_knowledge=${2:-0}; require_run "$id"; dir=$(run_dir "$id")
  verify_scope "$id" "$allow_knowledge"; patch=$(task_patch_fingerprint "$id"); state=$(section_value "$dir" handoff state)
  for gate in implemented code_done; do
    recorded=$(section_value "$dir" handoff "${gate}_patch_sha256")
    case "$recorded" in ''|PENDING) continue;; esac
    [ "$recorded" = "$patch" ] || fail "${gate} stale: task-owned patch changed; rerun affected gate"
  done
  [ -n "$state" ] || fail "handoff state missing"
  verify_lifecycle_gates "$id"
  echo "handoff integrity verified: $id"
}
delivery_check() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  [ "$(run_state "$dir")" = CODE_DONE ] || fail "delivery blocked: CODE_DONE required"
  branch=$(git -C "$root" branch --show-current); [ -n "$branch" ] || fail "delivery blocked: detached HEAD"
  enforce_task_branch "$id"
  verify_freshness "$id"
  # Application-scope integrity and knowledge-transaction integrity are
  # independently required for delivery, exactly mirroring the DONE handoff
  # transition (record_handoff's DONE case / .agents/WORKFLOW.md's
  # "Knowledge transaction scope"): a legitimate knowledge transaction DONE
  # already accepted must not become "delivery blocked" merely because this
  # check runs afterward — but an unexpected application-scope path, or an
  # unexpected/inconsistent knowledge-scope diff (no recorded transaction,
  # a mismatched not_applicable, or KNOWLEDGE_DONE with zero real diffs),
  # still fails closed exactly as it would at DONE.
  verify_scope "$id" 1
  verify_knowledge_scope "$id"
  verify_handoff "$id" 1
  patch=$(task_patch_fingerprint "$id"); [ "$(section_value "$dir" handoff implemented_patch_sha256)" = "$patch" ] || fail "delivery blocked: implementation stale or missing"
  [ "$(section_value "$dir" handoff code_done_patch_sha256)" = "$patch" ] || fail "delivery blocked: CODE_DONE handoff stale or missing"
  printf 'delivery_branch=%s\ndelivery_ready=true\n' "$branch"
}

# General structural sanity check for a run at any phase (not gated on
# CODE_DONE/DONE, unlike delivery_check) — required artifacts present,
# control-artifact set clean, scope mappings well-formed, baseline/freshness
# current, handoff integrity intact. It must apply the exact same
# allow_knowledge=1 relaxation delivery_check already uses for a
# captured-baseline run (verify_scope 1 -> verify_knowledge_scope ->
# verify_handoff 1): otherwise a completed Transaction B that DONE and
# delivery_check have both already accepted still fails validate purely
# because verify_handoff's own default is strict/0, which never had any
# concept of Transaction B at all (the exact bug DONE and delivery_check
# were separately fixed for). allow_knowledge only defers a real
# knowledge-scope path to verify_knowledge_scope's own independent
# judgment; it never approves one outright — an invalid, missing, or
# inconsistent knowledge-transaction state, or any unauthorized
# application-scope change, still fails validate closed exactly as before.
validate_run() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  for f in TASK.md PLAN.md RUN.yaml; do
    [ -f "$dir/$f" ] || fail "missing required artifact: $f"
  done
  [ "$(pipeline_needs "$id" evidence)" != yes ] || [ -f "$dir/EVIDENCE.md" ] || fail "missing required artifact: EVIDENCE.md"
  [ "$(pipeline_needs "$id" qa)" != yes ] || [ -f "$dir/QA_PLAN.md" ] || fail "missing required artifact: QA_PLAN.md"
  if section_key_present "$dir" completion_report required; then
    [ -f "$dir/COMPLETION_REPORT.md" ] || fail "missing required artifact: COMPLETION_REPORT.md"
  fi
  validate_control_artifacts "$id"
  scope_mappings "$dir/PLAN.md" >/dev/null
  status=$(baseline_status "$dir")
  [ "$status" = captured ] || fail "baseline missing or pending: $id"
  validate_captured_baseline "$dir"
  verify_freshness "$id"
  verify_scope "$id" 1
  verify_knowledge_scope "$id"
  verify_handoff "$id" 1
  echo "run validated: $id"
}

# Run metadata is deliberately separate from application scope. This exact allowlist
# applies only to the active run directory; no other .agents paths are ignored. It is
# pipeline-aware: an artifact the run's classification does not require (a QA_PLAN.md
# on a TRIVIAL run, say) is not control metadata, so it is rejected as an unexpected
# path — the mechanism that keeps runtime files from accumulating without a consumer.
known_control_artifact() {
  id=$1 path=$2
  case "$path" in
    ".agents/runs/$id/TASK.md"|".agents/runs/$id/PLAN.md"|".agents/runs/$id/RUN.yaml"|".agents/runs/$id/COMPLETION_REPORT.md"|".agents/runs/$id/amendments/"*|".agents/runs/$id/worker-evidence/"*|".agents/runs/$id/decisions/"*|".agents/runs/$id/gates/"*|".agents/runs/$id/LEDGER.log") return 0 ;;
    ".agents/runs/$id/EVIDENCE.md") [ "$(pipeline_needs "$id" evidence)" = yes ] && return 0 ;;
    ".agents/runs/$id/QA_PLAN.md") [ "$(pipeline_needs "$id" qa)" = yes ] && return 0 ;;
    ".agents/runs/$id/REVIEW.md"|".agents/runs/$id/QA_REPORT.md"|".agents/runs/$id/VERIFY.md")
      for kc_gate in $(pipeline_gates "$id"); do [ ".agents/runs/$id/$(gate_report_name "$kc_gate")" = "$path" ] && return 0; done ;;
  esac
  # A published completion report legitimately (and only then) mutates the
  # task's own task_source.path via a task-integration adapter — see
  # publish_completion_report. That single, narrowly-scoped, full_lifecycle-
  # only write is treated as control metadata, exactly like this run's own
  # COMPLETION_REPORT.md, rather than application scope drift. Before publication this
  # exemption does not apply, so an unrelated mid-IMPLEMENT edit to the task
  # source file is still correctly flagged.
  rundir=$(run_dir "$id")
  # After `amend` reopens a published run, the task source still holds the
  # previously published report until the next publication replaces it, so the
  # exemption also holds for a run that has been reopened.
  if [ "$(section_value "$rundir" completion_report published)" = true ] || ls "$rundir"/gates/*-REOPEN.yaml >/dev/null 2>&1; then
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
# gates branch-isolation policy (see `enforce_task_branch`). The run template
# carries the key; only the isolated fixture suites omit it.
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
# in REVIEW.md — see the RED-VALIDATED convention below); it only
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
  id=$1 phase=$2 result=$3; require_run "$id"; dir=$(run_dir "$id"); require_open_run "$id"
  topology=$(resolve_topology "$dir") || return 1
  expected_role=$(expected_implementation_owner "$topology") || return 1
  [ "$execution_role" = "$expected_role" ] || fail "command requires AGENT_ROLE=$expected_role for this run's execution topology ($topology)"
  case "$phase" in RED|GREEN|REFACTOR|FIX) ;; *) fail "invalid worker-evidence phase: $phase" ;; esac
  case "$result" in pass|fail) ;; *) fail "invalid worker-evidence result: $result (want pass|fail)" ;; esac
  [ "$(section_value "$dir" handoff state)" = IMPLEMENTING ] || fail "worker evidence may only be recorded while handoff state is IMPLEMENTING"
  verify_freeze "$id"
  enforce_task_branch "$id"
  verify_seal "$id"
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
  evdir=$(worker_evidence_dir "$id")
  mkdir -p "$evdir" || { rm -f "$scratch"; fail "worker evidence directory could not be created (sandbox denied write?): $evdir"; }
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
  } > "$out" 2>"$scratch.writeerr" || { we=$(cat "$scratch.writeerr" 2>/dev/null || true); rm -f "$scratch" "$scratch.writeerr" "$out" 2>/dev/null || true; fail "failed to write worker evidence file (sandbox denied write?): $out${we:+ ($we)}"; }
  rm -f "$scratch" "$scratch.writeerr"
  [ -s "$out" ] || { rm -f "$out"; fail "worker evidence file was not actually written (empty or missing after redirect): $out"; }
  grep -q '^task_id: ' "$out" || { rm -f "$out"; fail "worker evidence file is malformed (missing task_id): $out"; }
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
# a run without the worker_evidence policy key (see policy_enforced).
verify_worker_evidence() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  policy_enforced "$dir" || { echo "worker-evidence not policy-enforced for $id"; return 0; }
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

# ---------------------------------------------------------------------------
# Lifecycle gates, tree-attested mutation ownership, the lifecycle ledger, and
# the scripted reopen (`amend`) transition.
#
# Everything in this section is gated on `gates_enforced`: a run whose
# RUN.yaml carries the `lifecycle_gates:` key block (the run template does; only
# the isolated fixture suites omit it). New variables below use a g_ prefix on
# purpose: this script is POSIX sh with no `local`, and callers rely on
# id/dir/phase/patch/current surviving these calls.
#
# What it adds, in one paragraph: REVIEW, QA and VERIFY are first-class gates —
# which of them a run needs is decided by its classification (see the Pipeline
# section) — recorded as append-only evidence bound to the exact task-owned patch
# fingerprint and to the role-owned report they judged, so a byte changed after a
# gate voids it (the existing verify_handoff patch staleness already proved the
# tree; the gate records prove *who* judged it and with what independence). Under `orchestrated` topology every change to the
# application tree must be attested by the implementation_worker (evidence
# carries the tree before and after each worker window, chained), so an edit by
# any other actor breaks the chain. Every lifecycle transition is appended to a
# hash-chained ledger and the ledger's last digest must equal the digest of the
# RUN.yaml lifecycle fields, so a hand edit of those fields is detected. A run
# at CODE_DONE/DONE is reopened only by `amend`, which records why, preserves
# the prior completion history, and routes the fix through the same loop.
# ---------------------------------------------------------------------------
gates_enforced() { section_key_present "$(run_dir "$1")" lifecycle_gates required; }
policy_flag() { effective "$1" | sed -n "s/^$2=//p" | head -n 1; }
max_fix_attempts() { n=$(policy_flag "$1" verification.max_bounded_fix_attempts); case "$n" in ''|*[!0-9]*) n=2 ;; esac; printf '%s\n' "$n"; }
set_run_value() {
  g_d=$(run_dir "$1")
  replace_section_value "$g_d" "$2" "$3" "$4" "$g_d/RUN.yaml.tmp" || { rm -f "$g_d/RUN.yaml.tmp"; fail "RUN.yaml has no $2.$3 to set"; }
  mv "$g_d/RUN.yaml.tmp" "$g_d/RUN.yaml"
}
one_line() { printf '%s' "$1" | tr '\n\t' '  '; }
field_from() { sed -n "s/^$2: *//p" "$1" | head -1; }

# --- Lifecycle ledger (manual state-rewind detection + audit history) -------
ledger_file() { printf '%s/LEDGER.log\n' "$(run_dir "$1")"; }
_lv() { printf '%s.%s=%s\n' "$2" "$3" "$(section_value "$1" "$2" "$3")"; }
lifecycle_digest() {
  g_d=$(run_dir "$1")
  { _lv "$g_d" execution state; _lv "$g_d" execution knowledge_state; _lv "$g_d" handoff state
    _lv "$g_d" handoff implemented_patch_sha256; _lv "$g_d" handoff code_done_patch_sha256
    _lv "$g_d" pipeline classification; _lv "$g_d" pipeline review
    _lv "$g_d" completion_report published; _lv "$g_d" completion_report adapter; _lv "$g_d" completion_report receipt
    if local_task_source_run "$1"; then _lv "$g_d" task_source path; _lv "$g_d" task_source revision; fi
  } | shasum -a 256 | awk '{print $1}'
}
ledger_append() {
  g_id=$1 g_event=$2 g_from=$3 g_to=$4 g_detail=$(one_line "$5")
  g_file=$(ledger_file "$g_id"); g_seq=1 g_prev=genesis
  if [ -s "$g_file" ]; then
    g_last=$(tail -n 1 "$g_file")
    g_seq=$(( $(printf '%s' "$g_last" | sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p') + 1 ))
    g_prev=$(printf '%s' "$g_last" | shasum -a 256 | awk '{print $1}')
  fi
  printf 'seq=%s prev=%s event=%s role=%s from=%s to=%s digest=%s ts=%s detail=%s\n' "$g_seq" "$g_prev" "$g_event" "$execution_role" "$g_from" "$g_to" "$(lifecycle_digest "$g_id")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$g_detail" >> "$g_file" || fail "could not append to lifecycle ledger: $g_file"
}
# The ledger records every control-plane lifecycle transition; the digest of
# the RUN.yaml lifecycle fields at each step is sealed into the chain. If those
# fields no longer match the last sealed digest, something other than this
# script changed them. This cannot stop a determined same-user forger from
# re-sealing a rewritten ledger (see .agents/ENFORCEMENT.md "Evidence
# strength") — it makes a hand edit of lifecycle state, the manual-rewind
# failure mode, mechanically detectable instead of silently accepted.
verify_seal() {
  g_id=$1; gates_enforced "$g_id" || return 0
  g_d=$(run_dir "$g_id"); g_file=$(ledger_file "$g_id")
  if [ ! -s "$g_file" ]; then
    g_hs=$(section_value "$g_d" handoff state)
    case "$g_hs" in PLANNED|'') ;; *) fail "lifecycle ledger missing but handoff.state=$g_hs: manual lifecycle-state edit detected for $g_id" ;; esac
    [ "$(run_state "$g_d")" != CODE_DONE ] || fail "lifecycle ledger missing but execution.state=CODE_DONE: manual lifecycle-state edit detected for $g_id"
    [ "$(section_value "$g_d" completion_report published)" != true ] || fail "lifecycle ledger missing but a completion report is marked published: manual lifecycle-state edit detected for $g_id"
    return 0
  fi
  g_prev=genesis g_n=0 g_lastdigest=''
  while IFS= read -r g_line || [ -n "$g_line" ]; do
    g_n=$((g_n + 1))
    g_lseq=$(printf '%s' "$g_line" | sed -n 's/^seq=\([0-9][0-9]*\) prev=.*/\1/p')
    g_lprev=$(printf '%s' "$g_line" | sed -n 's/^seq=[0-9]* prev=\([^ ]*\) .*/\1/p')
    [ "$g_lseq" = "$g_n" ] && [ "$g_lprev" = "$g_prev" ] || fail "lifecycle ledger chain broken at entry $g_n for $g_id: ledger was edited"
    g_lastdigest=$(printf '%s' "$g_line" | sed -n 's/^seq=[0-9]* prev=[^ ]* event=[^ ]* role=[^ ]* from=[^ ]* to=[^ ]* digest=\([0-9a-f]*\) ts=.*/\1/p')
    g_prev=$(printf '%s' "$g_line" | shasum -a 256 | awk '{print $1}')
  done < "$g_file"
  [ "$g_lastdigest" = "$(lifecycle_digest "$g_id")" ] || fail "lifecycle state of $g_id does not match its last recorded control-plane transition: RUN.yaml lifecycle fields were edited by hand. A completed run is reopened only with 'agent.sh amend'"
}

# --- Gate records (REVIEW / QA / VERIFY / REOPEN) ---------------------------
gates_dir() { printf '%s/gates\n' "$(run_dir "$1")"; }
gate_field() { sed -n "s/^$2: *//p" "$1" | head -1 | tr -d '"'; }
gate_names() { ls -1 "$(gates_dir "$1")" 2>/dev/null | grep -E '^[0-9]{3}-(REVIEW|QA|VERIFY|REOPEN)\.yaml$' | sort || true; }
next_gate_seq() {
  n=0
  for f in $(gate_names "$1"); do s=$(gate_field "$(gates_dir "$1")/$f" seq); if [ "$s" -gt "$n" ]; then n=$s; fi; done
  printf '%d\n' $((n + 1))
}
last_reopen_seq() {
  n=0
  for f in $(gate_names "$1"); do case "$f" in *-REOPEN.yaml) n=$(gate_field "$(gates_dir "$1")/$f" seq) ;; esac; done
  printf '%s\n' "$n"
}
patch_manifest() {
  task_owned_paths "$1" | while IFS= read -r p; do
    if [ -n "$p" ]; then printf '%s|%s\n' "$p" "$(fingerprint_path "$p")"; fi
  done
}
# Structural, freeze-bound validity of one gate record: it belongs to this
# task, was recorded against the exact frozen task/evidence/plan/qa_plan hashes
# (a refreeze stales it), its manifest still hashes to what it recorded, and the
# role-owned report it names is unchanged.
valid_gate_file() {
  g_id=$1 g_f=$2 g_d=$(run_dir "$1")
  [ "$(gate_field "$g_f" task_id)" = "$g_id" ] || return 1
  for g_h in task evidence plan qa_plan policy; do [ "$(gate_field "$g_f" "${g_h}_sha256")" = "$(section_value "$g_d" freeze "${g_h}_sha256")" ] || return 1; done
  [ "$(gate_field "$g_f" pipeline)" = "$(section_value "$g_d" freeze pipeline)" ] || return 1
  g_m=${g_f%.yaml}.manifest; [ -f "$g_m" ] || return 1
  [ "$(gate_field "$g_f" manifest_sha256)" = "$(hash_file "$g_m")" ] || return 1
  # The gate is bound to the role-owned report it was recorded against: editing the report afterwards voids the pass.
  g_rep=$(gate_field "$g_f" report); [ -n "$g_rep" ] && [ -f "$g_d/$g_rep" ] || return 1
  [ "$(gate_field "$g_f" report_sha256)" = "$(hash_file "$g_d/$g_rep")" ] || return 1
  return 0
}
# Whether an author role satisfies a gate under this run's effective policy:
# the gate's own independent role (Reviewer, QA, Verifier) always does;
# full_lifecycle (self-review/self-QA/self-verification) does only when the
# policy does not require independence. implementation_worker, explorer and
# architect never author a gate.
gate_independent_role() { case "$1" in REVIEW) echo independent_reviewer ;; QA) echo independent_qa ;; VERIFY) echo independent_verifier ;; esac; }
gate_report_name() { case "$1" in REVIEW) echo REVIEW.md ;; QA) echo QA_REPORT.md ;; VERIFY) echo VERIFY.md ;; esac; }
gate_role_ok() {
  [ "$3" != "$(gate_independent_role "$2")" ] || return 0
  case "$2:$3" in
    REVIEW:full_lifecycle) [ "$(policy_flag "$1" review.independent)" != true ]; return ;;
    QA:full_lifecycle) [ "$(policy_flag "$1" qa.independent)" != true ]; return ;;
    VERIFY:full_lifecycle) [ "$(policy_flag "$1" verification.independent_verifier)" != true ]; return ;;
  esac
  return 1
}
# Sequence number of the qualifying, current PASS for <gate> on <patch>, or
# empty. Qualifying: latest record of that gate for this exact tree is a
# pass; freeze-bound valid; authored by an acceptable role; recorded after the
# most recent REOPEN; and not voided by a later fail of either gate on the
# same tree.
gate_pass_seq() {
  g_id=$1 g_gate=$2 g_patch=$3 g_gd=$(gates_dir "$1"); g_reopen=$(last_reopen_seq "$1"); g_found=''
  for g_n in $(gate_names "$g_id"); do
    g_f=$g_gd/$g_n
    [ "$(gate_field "$g_f" patch_sha256)" = "$g_patch" ] || continue
    g_s=$(gate_field "$g_f" seq); [ "$g_s" -gt "$g_reopen" ] || continue
    g_t=$(gate_field "$g_f" gate); g_r=$(gate_field "$g_f" result)
    if [ "$g_t" = "$g_gate" ]; then
      if [ "$g_r" = pass ] && valid_gate_file "$g_id" "$g_f" && gate_role_ok "$g_id" "$g_gate" "$(gate_field "$g_f" role)"; then g_found=$g_s; else g_found=''; fi
    elif [ "$g_r" = fail ]; then g_found=''; fi
  done
  printf '%s\n' "$g_found"
}
# A tree that already has a fail (or REOPEN) record against the current frozen
# plan is an open finding: it cannot collect further gate records or advance
# until a fix changes it.
# A gate record binds the whole frozen contract (task, evidence, plan and QA plan
# hashes), so an authorized amendment that changes any of them ends the previous
# findings' hold on the tree and starts a fresh fix budget.
gate_bound_to_contract() {
  g_bd=$(run_dir "$1")
  for g_bk in task evidence plan qa_plan; do
    [ "$(gate_field "$2" "${g_bk}_sha256")" = "$(section_value "$g_bd" freeze "${g_bk}_sha256")" ] || return 1
  done
}
open_finding_seq() {
  g_id=$1 g_patch=$2 g_gd=$(gates_dir "$1"); g_hit=''
  for g_n in $(gate_names "$g_id"); do
    g_f=$g_gd/$g_n
    [ "$(gate_field "$g_f" patch_sha256)" = "$g_patch" ] || continue
    gate_bound_to_contract "$g_id" "$g_f" || continue
    case "$(gate_field "$g_f" gate):$(gate_field "$g_f" result)" in REOPEN:*|REVIEW:fail|QA:fail|VERIFY:fail) g_hit=$(gate_field "$g_f" seq) ;; esac
  done
  printf '%s\n' "$g_hit"
}
fix_cycles_used() {
  g_id=$1 g_gd=$(gates_dir "$1"); g_reopen=$(last_reopen_seq "$1"); g_c=0
  for g_n in $(gate_names "$g_id"); do
    g_f=$g_gd/$g_n
    [ "$(gate_field "$g_f" result)" = fail ] || continue
    gate_bound_to_contract "$g_id" "$g_f" || continue
    [ "$(gate_field "$g_f" seq)" -gt "$g_reopen" ] || continue
    g_c=$((g_c + 1))
  done
  printf '%d\n' "$g_c"
}
latest_finding_file() {
  g_id=$1 g_gd=$(gates_dir "$1"); g_hit=''
  for g_n in $(gate_names "$g_id"); do
    g_f=$g_gd/$g_n
    gate_bound_to_contract "$g_id" "$g_f" || continue
    case "$(gate_field "$g_f" gate):$(gate_field "$g_f" result)" in REOPEN:*|REVIEW:fail|QA:fail|VERIFY:fail) g_hit=$g_f ;; esac
  done
  printf '%s\n' "$g_hit"
}

# A fix is bounded by the finding's contract: every application path whose
# fingerprint differs from the failing tree's manifest must be named in that
# finding's fix_scope, and the tree must actually have changed.
verify_fix_bound() {
  g_id=$1; gates_enforced "$g_id" || return 0
  g_f=$(latest_finding_file "$g_id"); [ -n "$g_f" ] || return 0
  g_patch=$(task_patch_fingerprint "$g_id")
  [ "$g_patch" != "$(gate_field "$g_f" patch_sha256)" ] || fail "no application/test change since the finding in ${g_f##*/}: a fix must change the tree before it can be re-reviewed"
  g_delta=$( { cat "${g_f%.yaml}.manifest"; patch_manifest "$g_id"; } | sed '/^$/d' | sort | uniq -u | cut -d '|' -f1 | sort -u )
  g_scope=$(gate_field "$g_f" fix_scope); g_bad=''
  for g_p in $g_delta; do
    printf '%s\n' "$g_scope" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fxq -- "$g_p" || g_bad="$g_bad $g_p"
  done
  [ -z "$g_bad" ] || fail "fix changed paths outside the finding's fix_scope (${g_f##*/}):$g_bad"
}

# Tree-attested mutation ownership. Under orchestrated topology every change
# to the task-owned application/test tree must come from the
# implementation_worker. scripts/worker-run.sh — the only sanctioned worker
# invocation, run by the orchestrator process *outside* the worker — brackets
# each worker run with `window-open` / `window-close`, which record the tree
# fingerprint before and after the window (worker-evidence/WINDOW-<n>.yaml).
# Windows must chain (each begins where the previous ended; the first from the
# pristine tree), and the tree now must equal the last window's end. A change
# made by anyone else — the orchestrator fixing something itself after review,
# say — leaves the tree different from the last attested end and is rejected.
# Attestation is by the wrapper, not by the worker's own bookkeeping, so a
# worker that forgets to record evidence cannot taint the chain. `force=1`
# checks even while handoff is still IMPLEMENTING (used by the IMPLEMENTED
# transition and by window-open).
window_files() { ls -1 "$(worker_evidence_dir "$1")" 2>/dev/null | grep -E '^WINDOW-[0-9]+\.yaml$' | sort -t - -k2,2n || true; }
pristine_tree() { printf '' | shasum -a 256 | awk '{print $1}'; }
last_attested_tree() {
  n=$(pristine_tree)
  for f in $(window_files "$1"); do n=$(evidence_field "$(worker_evidence_dir "$1")/$f" after_sha256); done
  printf '%s\n' "$n"
}
verify_mutation_ownership() {
  g_id=$1 g_force=${2:-0}; gates_enforced "$g_id" || return 0
  g_d=$(run_dir "$g_id"); g_topo=$(resolve_topology "$g_d") || return 1
  [ "$g_topo" = orchestrated ] || return 0
  g_hs=$(section_value "$g_d" handoff state)
  case "$g_hs" in IMPLEMENTED|CODE_DONE|DONE) ;; *) [ "$g_force" = 1 ] || return 0 ;; esac
  g_prev_after=$(pristine_tree); g_ev=$(worker_evidence_dir "$g_id")
  for g_w in $(window_files "$g_id"); do
    [ "$(evidence_field "$g_ev/$g_w" role)" = implementation_worker ] || fail "worker window ${g_w%.yaml} was not attested for implementation_worker"
    [ "$(evidence_field "$g_ev/$g_w" before_sha256)" = "$g_prev_after" ] || fail "unattributed application/test mutation before ${g_w%.yaml}: the tree changed between worker windows outside the implementation_worker"
    g_prev_after=$(evidence_field "$g_ev/$g_w" after_sha256)
  done
  g_tree=$(task_patch_fingerprint "$g_id")
  [ "$g_tree" = "$g_prev_after" ] || fail "application/test tree ($g_tree) is not the last implementation_worker-attested tree ($g_prev_after): a mutation was made outside the worker under orchestrated topology; undo it and route the change through the implementation_worker (scripts/worker-run.sh)"
}
# window-open prints the tree fingerprint the worker window starts from (after
# proving the tree is still the last attested one); window-close records the
# window. Both are no-ops for a run that is not lifecycle_gates + orchestrated,
# so scripts/worker-run.sh can call them unconditionally.
window_open() {
  g_id=$1; require_run "$g_id"; gates_enforced "$g_id" || return 0
  require_open_run "$g_id"
  g_d=$(run_dir "$g_id"); [ "$(resolve_topology "$g_d")" = orchestrated ] || return 0
  [ "$(section_value "$g_d" handoff state)" = IMPLEMENTING ] || fail "worker windows are opened only while handoff state is IMPLEMENTING"
  verify_seal "$g_id"; verify_mutation_ownership "$g_id" 1
  task_patch_fingerprint "$g_id"
}
window_close() {
  g_id=$1 g_before=$2 g_status=${3:-0}; require_run "$g_id"; gates_enforced "$g_id" || return 0
  require_open_run "$g_id"
  g_d=$(run_dir "$g_id"); [ "$(resolve_topology "$g_d")" = orchestrated ] || return 0
  [ -n "$g_before" ] || fail "window-close requires the fingerprint printed by window-open"
  [ "$(section_value "$g_d" handoff state)" = IMPLEMENTING ] || fail "worker windows are closed only while handoff state is IMPLEMENTING"
  [ "$g_before" = "$(last_attested_tree "$g_id")" ] || fail "worker window began at a tree that is not the last attested one: unattributed mutation"
  g_ev=$(worker_evidence_dir "$g_id"); mkdir -p "$g_ev" || fail "cannot create $g_ev"
  g_n=$(next_evidence_seq "$g_ev" WINDOW)
  {
    printf 'task_id: "%s"\nseq: %s\nrole: "implementation_worker"\ntopology: "orchestrated"\n' "$g_id" "$g_n"
    printf 'before_sha256: "%s"\nafter_sha256: "%s"\nexit_status: "%s"\n' "$g_before" "$(task_patch_fingerprint "$g_id")" "$g_status"
    printf 'timestamp: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$g_ev/WINDOW-$g_n.yaml" || fail "could not write worker window record"
  echo "worker window recorded: $g_id WINDOW-$g_n"
}

# Gate/ledger/ownership integrity for the run's current handoff state; called
# by verify_handoff (and therefore validate, delivery-check and `verify-handoff`).
verify_lifecycle_gates() {
  g_id=$1; gates_enforced "$g_id" || return 0
  g_d=$(run_dir "$g_id"); g_hs=$(section_value "$g_d" handoff state)
  verify_seal "$g_id"
  verify_mutation_ownership "$g_id"
  case "$g_hs" in CODE_DONE|DONE) verify_required_gates "$g_id" "$(task_patch_fingerprint "$g_id")" "gate evidence missing or stale" ;; esac
}

# The quality gate: every gate the run's pipeline requires (REVIEW/QA/VERIFY) holds a
# current, valid, sufficiently independent pass for this exact application tree.
# The gates are independent of each other — there is no required order; any change to
# the tree voids all of them at once.
verify_required_gates() {
  g_id=$1 g_patch=$2 g_msg=$3
  for g_gate in $(pipeline_gates "$g_id"); do
    [ -n "$(gate_pass_seq "$g_id" "$g_gate" "$g_patch")" ] || fail "$g_msg: no current, valid, sufficiently independent $g_gate pass for this exact application tree of $g_id (see 'agent.sh gate')"
  done
}

# Records one REVIEW, QA or VERIFY gate result — the three independent
# post-implementation judgments (Reviewer: is it good; QA: does the behavior meet
# the frozen QA plan; Verifier: can the repository prove the frozen plan was
# implemented). The gate must be one the run's pipeline requires, and the role's
# own report (REVIEW.md / QA_REPORT.md / VERIFY.md, ending in a `Verdict: PASS|FAIL`
# line that matches the result) must already exist; the gate binds its hash.
# Fields on stdin: summary (what was checked, >=20 chars); for a fail also
# findings, fix_scope (comma-separated frozen-scope paths) and fix_instruction —
# the bounded fix contract the implementation owner must work to. A BLOCKED
# verdict (the role could not evaluate: tooling/environment) records no gate; it
# returns to the orchestrator, which resolves it or terminates the run BLOCKED.
record_gate() {
  g_id=$1 g_gate=$2 g_result=$3; require_run "$g_id"; g_d=$(run_dir "$g_id")
  gates_enforced "$g_id" || fail "run $g_id has no lifecycle_gates policy: REVIEW/QA/VERIFY gates are not recorded for it"
  require_open_run "$g_id"
  case "$g_gate" in REVIEW|QA|VERIFY) ;; *) fail "invalid gate: $g_gate (want REVIEW|QA|VERIFY)" ;; esac
  case "$g_result" in pass|fail) ;; *) fail "invalid gate result: $g_result (want pass|fail)" ;; esac
  [ "$execution_role" = full_lifecycle ] || [ "$execution_role" = "$(gate_independent_role "$g_gate")" ] || fail "role $execution_role may not record a $g_gate gate"
  pipeline_gates "$g_id" | grep -Fxq "$g_gate" || fail "the $(pipeline_class "$g_id") pipeline of $g_id does not include a $g_gate gate (required: $(pipeline_gates "$g_id" | tr '\n' ' '))"
  enforce_task_branch "$g_id"; verify_freshness "$g_id"; verify_seal "$g_id"
  [ "$(section_value "$g_d" handoff state)" = IMPLEMENTED ] || fail "$g_gate gate may only be recorded while handoff state is IMPLEMENTED"
  verify_scope "$g_id" 0 >/dev/null
  g_patch=$(task_patch_fingerprint "$g_id")
  [ "$(section_value "$g_d" handoff implemented_patch_sha256)" = "$g_patch" ] || fail "$g_gate gate blocked: the application tree changed since IMPLEMENTED"
  verify_mutation_ownership "$g_id"
  [ -z "$(open_finding_seq "$g_id" "$g_patch")" ] || fail "$g_gate gate blocked: this exact tree already has an open finding; the implementation owner must fix it first"
  if [ "$g_result" = pass ]; then
    gate_role_ok "$g_id" "$g_gate" "$execution_role" || fail "$g_gate pass rejected: policy requires an independent author ($(gate_independent_role "$g_gate")) and role '$execution_role' is not independent"
  fi
  g_report=$(gate_report_name "$g_gate")
  [ -s "$g_d/$g_report" ] || fail "$g_gate gate requires the role's report $g_report in the run directory (see .agents/templates/$g_report)"
  [ "$(grep -c '^Verdict:' "$g_d/$g_report")" = 1 ] || fail "$g_report must contain exactly one 'Verdict:' line"
  g_verdict=$(sed -n 's/^Verdict: *//p' "$g_d/$g_report" | tr -d ' ')
  case "$g_result:$g_verdict" in pass:PASS|fail:FAIL) ;; *) fail "$g_report says 'Verdict: ${g_verdict:-<missing>}' but the gate result is '$g_result' (pass needs Verdict: PASS, fail needs Verdict: FAIL; a BLOCKED verdict records no gate)" ;; esac
  g_scratch=$(mktemp "${TMPDIR:-/tmp}/agent-gate.XXXXXX"); cat > "$g_scratch"
  g_summary=$(field_from "$g_scratch" summary); g_findings=$(field_from "$g_scratch" findings); g_fscope=$(field_from "$g_scratch" fix_scope); g_finstr=$(field_from "$g_scratch" fix_instruction)
  rm -f "$g_scratch"
  reject_generic_justification "$g_summary" || fail "$g_gate gate requires a specific summary (>=20 chars, not a stock phrase)"
  if [ "$g_result" = fail ]; then
    reject_generic_justification "$g_findings" || fail "a failing gate requires specific findings (>=20 chars)"
    reject_generic_justification "$g_finstr" || fail "a failing gate requires a specific fix_instruction (>=20 chars)"
    [ -n "$g_fscope" ] || fail "a failing gate requires fix_scope (comma-separated frozen-scope paths the fix may touch)"
    g_maps=$(scope_mappings "$g_d/PLAN.md") || fail "invalid scope mapping"
    for g_p in $(printf '%s' "$g_fscope" | tr ',' ' '); do authorized_path "$g_maps" "$g_p" || fail "fix_scope names a path outside the frozen scope: $g_p"; done
  fi
  g_seq=$(next_gate_seq "$g_id"); [ "$g_seq" -le 999 ] || fail "gate record limit reached"
  g_name=$(printf '%03d-%s' "$g_seq" "$g_gate"); g_gd=$(gates_dir "$g_id"); mkdir -p "$g_gd" || fail "cannot create $g_gd"
  patch_manifest "$g_id" > "$g_gd/$g_name.manifest" || fail "could not write gate manifest"
  {
    printf 'task_id: "%s"\nseq: %s\ngate: "%s"\nresult: "%s"\nrole: "%s"\n' "$g_id" "$g_seq" "$g_gate" "$g_result" "$execution_role"
    printf 'topology: "%s"\n' "$(resolve_topology "$g_d")"
    printf 'patch_sha256: "%s"\nmanifest_sha256: "%s"\n' "$g_patch" "$(hash_file "$g_gd/$g_name.manifest")"
    printf 'report: "%s"\nreport_sha256: "%s"\n' "$g_report" "$(hash_file "$g_d/$g_report")"
    printf 'task_sha256: "%s"\nevidence_sha256: "%s"\nplan_sha256: "%s"\nqa_plan_sha256: "%s"\n' "$(section_value "$g_d" freeze task_sha256)" "$(section_value "$g_d" freeze evidence_sha256)" "$(section_value "$g_d" freeze plan_sha256)" "$(section_value "$g_d" freeze qa_plan_sha256)"
    printf 'policy_sha256: "%s"\npipeline: "%s"\n' "$(section_value "$g_d" freeze policy_sha256)" "$(section_value "$g_d" freeze pipeline)"
    printf 'summary: %s\n' "$(one_line "$g_summary")"
    if [ "$g_result" = fail ]; then printf 'findings: %s\nfix_scope: %s\nfix_instruction: %s\n' "$(one_line "$g_findings")" "$g_fscope" "$(one_line "$g_finstr")"; fi
    printf 'timestamp: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$g_gd/$g_name.yaml" || fail "could not write gate record"
  [ -s "$g_gd/$g_name.yaml" ] || { rm -f "$g_gd/$g_name.yaml" "$g_gd/$g_name.manifest"; fail "gate record was not written"; }
  ledger_append "$g_id" "gate:$g_gate:$g_result" IMPLEMENTED IMPLEMENTED "$g_name by $execution_role"
  g_lc=$(printf '%s' "$g_gate" | tr 'A-Z' 'a-z'); g_att=$(ls -1 "$g_gd" | grep -c -- "-$g_gate\\.yaml\$" || true)
  workflow_event "$g_id" --event gate --stage "$g_lc" --gate "$g_lc" --status "$(ev_result "$g_result")" --attempt "$g_att" --findings-open "$([ "$g_result" = fail ] && echo 1 || echo 0)" --fingerprint "$g_patch"
  echo "gate recorded: $g_id $g_name ($g_result)"
}

# Called by the IMPLEMENTING transition out of IMPLEMENTED: reopens the
# implementation phase for exactly one bounded fix of an open finding.
reopen_for_fix() {
  g_id=$1 g_patch=$2
  [ -n "$(open_finding_seq "$g_id" "$g_patch")" ] || fail "no open gate finding on the current tree: nothing to fix, and a run does not return to IMPLEMENTING without one"
  g_used=$(fix_cycles_used "$g_id"); g_max=$(max_fix_attempts "$g_id")
  [ "$g_used" -le "$g_max" ] || fail "bounded fix attempts exhausted ($g_used failing gates against this plan, max $g_max fixes): escalate — an explicit plan amendment and refreeze is required to continue"
  set_run_value "$g_id" handoff implemented_patch_sha256 PENDING
  set_run_value "$g_id" handoff code_done_patch_sha256 PENDING
  workflow_event "$g_id" --event remediation --stage implement --status started --loop "$g_used"
}

# A plan amendment (refreeze) stales all frozen-hash-bound evidence, so a
# lifecycle_gates run that is past IMPLEMENTING returns to IMPLEMENTING with
# every downstream gate invalidated — the scripted path back that a refreeze
# during review/QA previously lacked. It is also the explicit escalation valve
# when the bounded fix attempts are exhausted: findings are counted per frozen
# plan, so an authorized amendment starts a fresh budget.
refreeze_lifecycle() {
  g_id=$1 g_amend=$2; g_d=$(run_dir "$g_id"); g_hs=$(section_value "$g_d" handoff state); g_to=$g_hs
  case "$g_hs" in
    IMPLEMENTED)
      set_run_value "$g_id" handoff state IMPLEMENTING
      set_run_value "$g_id" handoff implemented_patch_sha256 PENDING
      set_run_value "$g_id" handoff code_done_patch_sha256 PENDING
      g_to=IMPLEMENTING ;;
  esac
  ledger_append "$g_id" refreeze "$g_hs" "$g_to" "amendment $g_amend"
}

# The scripted reopen of a CODE_DONE/DONE run (the only sanctioned way to reopen one).
# Fields on stdin: reason, fix_scope, fix_instruction, authorized_by. Frozen
# TASK/EVIDENCE/PLAN are untouched; if the plan itself must change, follow with
# an amendment file and `refreeze` as usual (execution.state is AMENDING, so
# refreeze is permitted). The prior completion record is preserved in the
# REOPEN gate record; every downstream gate and the published report are
# invalidated by construction (patch PENDING, published=false).
amend_run() {
  g_id=$1; require_run "$g_id"; g_d=$(run_dir "$g_id"); require_full_lifecycle
  gates_enforced "$g_id" || fail "amend requires the lifecycle_gates policy: run $g_id has none, so it cannot be reopened; open a new task"
  require_open_run "$g_id"
  [ "$(run_state "$g_d")" = CODE_DONE ] || fail "amend reopens a CODE_DONE/DONE run only (execution.state is '$(run_state "$g_d")'); before CODE_DONE, findings go through the gates and the bounded fix loop"
  enforce_task_branch "$g_id"; verify_seal "$g_id"; verify_freshness "$g_id"; verify_handoff "$g_id" 1 >/dev/null
  g_scratch=$(mktemp "${TMPDIR:-/tmp}/agent-amend.XXXXXX"); cat > "$g_scratch"
  g_reason=$(field_from "$g_scratch" reason); g_fscope=$(field_from "$g_scratch" fix_scope); g_finstr=$(field_from "$g_scratch" fix_instruction); g_auth=$(field_from "$g_scratch" authorized_by); g_pchange=$(field_from "$g_scratch" plan_change)
  rm -f "$g_scratch"
  reject_generic_justification "$g_reason" || fail "amend requires a specific reason (>=20 chars)"
  reject_generic_justification "$g_finstr" || fail "amend requires a specific fix_instruction (>=20 chars)"
  [ "${#g_auth}" -ge 3 ] || fail "amend requires authorized_by (who authorized reopening a completed run)"
  [ -n "$g_fscope" ] || fail "amend requires fix_scope (comma-separated paths the fix may touch)"
  if [ "$g_pchange" != yes ]; then
    g_maps=$(scope_mappings "$g_d/PLAN.md") || fail "invalid scope mapping"
    for g_p in $(printf '%s' "$g_fscope" | tr ',' ' '); do authorized_path "$g_maps" "$g_p" || fail "fix_scope names a path outside the frozen scope: $g_p (add 'plan_change: yes' and follow with an amendment + refreeze if the plan itself must change)"; done
  fi
  g_patch=$(task_patch_fingerprint "$g_id"); g_seq=$(next_gate_seq "$g_id"); g_name=$(printf '%03d-REOPEN' "$g_seq"); g_gd=$(gates_dir "$g_id"); mkdir -p "$g_gd" || fail "cannot create $g_gd"
  patch_manifest "$g_id" > "$g_gd/$g_name.manifest" || fail "could not write reopen manifest"
  [ -f "$g_d/COMPLETION_REPORT.md" ] && cp "$g_d/COMPLETION_REPORT.md" "$g_gd/$g_name.completion-report.md"
  g_prev_hs=$(section_value "$g_d" handoff state)
  {
    printf 'task_id: "%s"\nseq: %s\ngate: "REOPEN"\nresult: "reopen"\nrole: "%s"\n' "$g_id" "$g_seq" "$execution_role"
    printf 'patch_sha256: "%s"\nmanifest_sha256: "%s"\n' "$g_patch" "$(hash_file "$g_gd/$g_name.manifest")"
    printf 'task_sha256: "%s"\nevidence_sha256: "%s"\nplan_sha256: "%s"\nqa_plan_sha256: "%s"\n' "$(section_value "$g_d" freeze task_sha256)" "$(section_value "$g_d" freeze evidence_sha256)" "$(section_value "$g_d" freeze plan_sha256)" "$(section_value "$g_d" freeze qa_plan_sha256)"
    printf 'reason: %s\nauthorized_by: %s\nfix_scope: %s\nfix_instruction: %s\n' "$(one_line "$g_reason")" "$(one_line "$g_auth")" "$g_fscope" "$(one_line "$g_finstr")"
    printf 'plan_change: %s\n' "${g_pchange:-no}"
    printf 'previous_execution_state: "%s"\nprevious_handoff_state: "%s"\nprevious_knowledge_state: "%s"\n' "$(run_state "$g_d")" "$g_prev_hs" "$(section_value "$g_d" execution knowledge_state)"
    printf 'previous_implemented_patch_sha256: "%s"\nprevious_code_done_patch_sha256: "%s"\n' "$(section_value "$g_d" handoff implemented_patch_sha256)" "$(section_value "$g_d" handoff code_done_patch_sha256)"
    printf 'previous_completion_published: "%s"\nprevious_completion_receipt: "%s"\n' "$(section_value "$g_d" completion_report published)" "$(section_value "$g_d" completion_report receipt)"
    printf 'timestamp: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$g_gd/$g_name.yaml" || fail "could not write reopen record"
  set_run_value "$g_id" execution state AMENDING
  if section_key_present "$g_d" execution knowledge_state; then set_run_value "$g_id" execution knowledge_state not_started; fi
  set_run_value "$g_id" handoff state IMPLEMENTING
  set_run_value "$g_id" handoff implemented_patch_sha256 PENDING
  set_run_value "$g_id" handoff code_done_patch_sha256 PENDING
  if section_key_present "$g_d" completion_report published; then set_run_value "$g_id" completion_report published false; set_run_value "$g_id" completion_report receipt PENDING; fi
  ledger_append "$g_id" REOPEN "$g_prev_hs" IMPLEMENTING "$g_name authorized_by=$g_auth: $g_reason"
  echo "run reopened: $g_id ($g_name); handoff IMPLEMENTING, execution AMENDING — implement the bounded fix, then every required gate runs again"
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
  dir=$1 id=$(basename "$1")
  printf '## Implementation Summary\n## Verification\n## Known Limitations / Follow-up\n'
  pipeline_gates "$id" | grep -Fxq REVIEW && printf '## Review Result\n'
  pipeline_gates "$id" | grep -Fxq QA && printf '## QA Result\n'
  [ -d "$(worker_evidence_dir "$(basename "$dir")")" ] && printf '## TDD Evidence\n'
  [ -d "$dir/amendments" ] && [ -n "$(ls -A "$dir/amendments" 2>/dev/null)" ] && printf '## Amendments\n'
  ls "$dir"/gates/*-REOPEN.yaml >/dev/null 2>&1 && printf '## Reopen History\n'
  return 0
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
  verify_seal "$id"
  validate_completion_report_structure "$id"
  script=$(adapter_script "$adapter") || return 1
  # Publishing is bookkeeping, never a re-baseline. The frozen contract must be
  # fresh before the adapter writes, the adapter may only change the
  # projected-out report block, and the recorded revision is not touched here.
  # Any deviation restores the task source byte for byte and fails closed
  # before anything is recorded.
  contract_backup=''
  if local_task_source_run "$id"; then
    verify_freshness "$id" >/dev/null
    contract_backup=$(mktemp "${TMPDIR:-/tmp}/agent-task-source.XXXXXX"); cp -p "$(local_task_source "$dir")" "$contract_backup"
  fi
  if ! receipt=$("$script" publish "$id" "$dir/COMPLETION_REPORT.md"); then
    [ -z "$contract_backup" ] || { cp -p "$contract_backup" "$(local_task_source "$dir")"; rm -f "$contract_backup"; }
    fail "completion report publish failed via adapter: $adapter"
  fi
  [ -n "$receipt" ] || { [ -z "$contract_backup" ] || { cp -p "$contract_backup" "$(local_task_source "$dir")"; rm -f "$contract_backup"; }; fail "adapter $adapter returned an empty receipt"; }
  if [ -n "$contract_backup" ]; then
    # A separate process on purpose: a function called in an `if` condition runs
    # with `set -e` disabled, so verify_freshness's inner `fail`s would be lost.
    if ! "$root/scripts/agent.sh" freshness "$id" >/dev/null 2>&1; then
      cp -p "$contract_backup" "$(local_task_source "$dir")"; rm -f "$contract_backup"
      fail "adapter $adapter changed the frozen task contract outside the completion-report block; the task source was restored and nothing was recorded"
    fi
    rm -f "$contract_backup"
  fi
  tmp=$dir/RUN.yaml.tmp
  replace_section_value "$dir" completion_report adapter "$adapter" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  replace_section_value "$dir" completion_report published true "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
  replace_section_value "$dir" completion_report receipt "$receipt" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
  if gates_enforced "$id"; then ledger_append "$id" publish-completion-report CODE_DONE CODE_DONE "$adapter $receipt"; fi
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
# The one sanctioned way to change where a contract-scheme run's task source
# lives (the task file moves todo/ -> in-progress/ -> done/).
# It is a move, not a re-baseline: the frozen contract at the new location must
# hash exactly to the revision recorded by freeze, the old location must be
# gone, and nothing may change once the completion report is published (its
# receipt binds the location). The new path is sealed into the lifecycle ledger.
task_source_relocate() {
  id=$1 new=$2; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  local_task_source_run "$id" || fail "task-source-relocate requires a local Markdown task source"
  freeze_hash_present "$dir" || fail "the task source can be relocated only after the run is frozen"
  [ "$(section_value "$dir" completion_report published)" != true ] || fail "cannot relocate the task source after the completion report is published: its receipt binds the location"
  verify_freeze "$id" >/dev/null; enforce_task_branch "$id"; verify_seal "$id"
  case "$new" in ''|/*|*'..'*|*'//'*) fail "invalid task source path: $new" ;; esac
  old=$(section_value "$dir" task_source path)
  [ "$new" != "$old" ] || fail "the task source is already recorded at $old"
  { [ ! -e "$root/$old" ] && [ ! -L "$root/$old" ]; } || fail "the task source still exists at $old: a relocation is a move, not a copy"
  [ ! -L "$root/$new" ] || fail "task source must not be a symlink: $new"
  [ -f "$root/$new" ] || fail "task source missing or non-regular: $new"
  [ "$(section_value "$dir" task_source revision)" = "$(task_source_contract_hash "$id" "$root/$new")" ] || fail "the task contract at $new differs from the frozen contract (only the Status value and the published completion-report block may differ); amendment and refreeze required"
  replace_section_value "$dir" task_source path "$new" "$dir/RUN.yaml.tmp" && mv "$dir/RUN.yaml.tmp" "$dir/RUN.yaml"
  if gates_enforced "$id"; then ledger_append "$id" task-source-relocate "$(section_value "$dir" handoff state)" "$(section_value "$dir" handoff state)" "$old -> $new"; fi
  echo "task source relocated: $id $old -> $new"
}

# Synchronize the task source's `**Status:**` line with its lifecycle folder. Only the
# Status value changes: when a contract is frozen it must still hash to the recorded
# revision afterwards, so this is never a way to edit the contract.
task_source_status() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle; require_open_run "$id"
  local_task_source_run "$id" || fail "task-source-status requires a local Markdown task source"
  [ "$(section_value "$dir" completion_report published)" != true ] || fail "cannot change the task source status after the completion report is published: its receipt binds the task source"
  enforce_task_branch "$id"; verify_seal "$id"
  path=$(section_value "$dir" task_source path); source=$(local_task_source "$dir")
  want=$(lifecycle_folder_status "$path")
  [ -n "$want" ] || fail "task source $path is not under a lifecycle folder (backlog/, todo/, in-progress/ or done/): nothing to synchronize"
  have=$(declared_task_status "$source"); [ -n "$have" ] || fail "task source $path has no **Status:** line"
  [ "$have" != "$want" ] || { echo "task source status already $want: $id"; return 0; }
  revision=$(section_value "$dir" task_source revision)
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-task-status.XXXXXX")
  awk -v s="$want" '/^\*\*Status:\*\*/ { print "**Status:** " s; next } { print }' "$source" > "$tmp"
  case "$revision" in ''|PENDING|not_applicable) : ;; *)
    [ "$revision" = "$(task_source_contract_hash "$id" "$tmp")" ] || { rm -f "$tmp"; fail "refusing to change the task source: the frozen task contract would change; amendment and refreeze required"; } ;;
  esac
  cat "$tmp" > "$source"; rm -f "$tmp"
  if gates_enforced "$id"; then ledger_append "$id" task-source-status "$(section_value "$dir" handoff state)" "$(section_value "$dir" handoff state)" "$path: $have -> $want"; fi
  echo "task source status synchronized: $id $path $have -> $want"
}

# Terminal outcome for a run that cannot complete. FAILED is only for a run whose bounded
# fix budget is exhausted (fix_cycles_used > max) — the retry limit, never a judgment call;
# BLOCKED is for a blocker outside the implementation (environment, tooling, an external
# dependency). Both require a reason and the evidence behind it, and the run is then
# terminal. The run directory is kept so the evidence can be reported; `cleanup` disposes of it.
terminate_run() {
  id=$1 outcome=$2; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  case "$outcome" in FAILED|BLOCKED) ;; *) fail "invalid outcome: $outcome (want FAILED|BLOCKED)" ;; esac
  gates_enforced "$id" || fail "terminate requires the lifecycle_gates policy"
  require_open_run "$id"
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "a CODE_DONE run is complete, not terminated"
  enforce_task_branch "$id"; verify_seal "$id"
  scratch=$(mktemp "${TMPDIR:-/tmp}/agent-terminate.XXXXXX"); cat > "$scratch"
  reason=$(field_from "$scratch" reason); evidence=$(field_from "$scratch" evidence); rm -f "$scratch"
  reject_generic_justification "$reason" || fail "terminate requires a specific reason (>=20 chars)"
  reject_generic_justification "$evidence" || fail "terminate requires the evidence behind it (>=20 chars: the failing gate records, the failing command and its output)"
  if [ "$outcome" = FAILED ]; then
    used=$(fix_cycles_used "$id"); max=$(max_fix_attempts "$id")
    [ "$used" -gt "$max" ] || fail "FAILED requires the bounded fix budget to be exhausted ($used failing gates against this plan, max $max fixes); use BLOCKED for an environment/tooling/external blocker"
  fi
  prev=$(run_state "$dir")
  set_run_value "$id" execution state "$outcome"
  ledger_append "$id" terminate "$prev" "$outcome" "reason: $reason; evidence: $evidence"
  workflow_event "$id" --event outcome --stage "$([ "$(section_value "$dir" handoff state)" = PLANNED ] && echo plan || echo implement)" --status "$([ "$outcome" = FAILED ] && echo failed || echo blocked)"
  echo "run terminated: $id $outcome"
}

# Runtime cleanup: the last act of a task. Runtime artifacts are disposable working state,
# not project documentation, so a completed run directory is deleted (durable knowledge
# belongs in permanent documentation, updated only when the task changed a durable
# contract). A DONE run must still verify cleanly first; a FAILED/BLOCKED run is disposed of
# only after its evidence has been reported. Clears the ACTIVE_RUN selector if it names this run.
cleanup_run() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle
  [ ! -L "$dir" ] && [ "$(dirname "$dir")" = "$root/.agents/runs" ] || fail "refusing to remove $dir: not a plain run directory"
  case "$(run_state "$dir")" in
    FAILED|BLOCKED)
      verify_seal "$id"; tail -n 1 "$(ledger_file "$id")" | grep -Fq "event=terminate " || fail "cleanup of a $(run_state "$dir") run requires its ledgered terminate transition: $id" ;;
    *)
      [ "$(section_value "$dir" handoff state)" = DONE ] || fail "cleanup requires handoff DONE (or a FAILED/BLOCKED run): $id"
      verify_freshness "$id" >/dev/null; verify_handoff "$id" 1 >/dev/null
      if section_key_present "$dir" completion_report required; then verify_completion_report "$id" >/dev/null; fi ;;
  esac
  marker=$root/$(config_value active_run_file "$config")
  if [ -f "$marker" ] && [ "$(sed '/^[[:space:]]*$/d' "$marker")" = "$id" ]; then : > "$marker"; fi
  rm -rf "$dir"
  rm -f -- "$(report_path "$id")" 2>/dev/null || true   # the task's disposable report (this one path); a failure never fails cleanup
  echo "run cleaned up: $id (runtime artifacts removed; ACTIVE_RUN cleared)"
}

# --- Read-only projections: summary (terminal) and report (disposable HTML) ---------------
# Both read canonical run files and never write to the repository. An absent fact is "unavailable".
# Neither is evidence: .agents/OVERSIGHT.md.
ua() { if [ -n "$1" ]; then printf '%s' "$1"; else printf unavailable; fi; }
projection_task() { pt=${1:-}; [ -n "$pt" ] || pt=$(active_run) || return 1; [ -n "$pt" ] || fail "no active task: pass a TASK-ID"; require_run "$pt"; printf '%s\n' "$pt"; }
report_dir() { rd_t=${TMPDIR:-/tmp}; printf '%s/agent-oversight-%s\n' "${rd_t%/}" "$(printf '%s' "$root" | shasum -a 256 | cut -c1-16)"; }
report_path() { printf '%s/%s.html\n' "$(report_dir)" "$1"; }
gate_scan() { # ID GATE -> gs_n (records of that gate) and gs_r (result of the latest)
  gs_n=0; gs_r=''
  for gs_f in $(gate_names "$1"); do
    [ "$(gate_field "$(gates_dir "$1")/$gs_f" gate)" = "$2" ] || continue
    gs_n=$((gs_n + 1)); gs_r=$(gate_field "$(gates_dir "$1")/$gs_f" result)
  done
}
gate_line() { # ID GATE
  if ! pipeline_declared "$1" || ! pipeline_class_valid "$(pipeline_class "$1")"; then printf unavailable
  elif ! pipeline_gates "$1" | grep -Fxq "$2"; then printf 'not required'
  else gate_scan "$1" "$2"; if [ "$gs_n" = 0 ]; then printf unavailable; else printf '%s (attempts %s)' "$gs_r" "$gs_n"; fi; fi
}
changed_paths() { task_owned_paths "$1" 2>/dev/null; } # unavailable when the plan scope cannot be read
summary_run() {
  sm_id=$(projection_task "${1:-}") || return 1; sm_d=$(run_dir "$sm_id")
  sm_topo=$(resolve_topology "$sm_d" 2>/dev/null) || sm_topo=''
  sm_chg=unavailable; sm_open=unavailable; sm_fails=0
  if sm_paths=$(changed_paths "$sm_id"); then
    sm_chg=$(printf '%s\n' "$sm_paths" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ -n "$(open_finding_seq "$sm_id" "$(task_patch_fingerprint "$sm_id")")" ]; then sm_open=1; else sm_open=0; fi
  fi
  for sm_f in $(gate_names "$sm_id"); do if [ "$(gate_field "$(gates_dir "$sm_id")/$sm_f" result)" = fail ]; then sm_fails=$((sm_fails + 1)); fi; done
  printf 'STATUS: %s (handoff %s, knowledge %s)\n' "$(ua "$(run_state "$sm_d")")" "$(ua "$(section_value "$sm_d" handoff state)")" "$(ua "$(section_value "$sm_d" execution knowledge_state)")"
  printf 'TASK: %s %s\n' "$sm_id" "$(sed -n '1s/^#[[:space:]]*//p' "$sm_d/TASK.md" 2>/dev/null | tr -d '\000-\037\177')"
  printf 'CLASS/TOPOLOGY: %s / %s\n' "$(ua "$(pipeline_class "$sm_id" | grep -v PENDING || true)")" "$(ua "$sm_topo")"
  printf 'CHANGED: %s\n' "$sm_chg"
  for sm_g in REVIEW QA VERIFY; do printf '%s: %s\n' "$sm_g" "$(gate_line "$sm_id" "$sm_g")"; done
  printf 'FINDINGS: open %s, failing gate records %s\n' "$sm_open" "$sm_fails"
  printf 'DELIVERY: handoff %s, completion report published %s\n' "$(ua "$(section_value "$sm_d" handoff state)")" "$(ua "$(section_value "$sm_d" completion_report published)")"
  if [ -f "$(report_path "$sm_id")" ]; then printf 'REPORT: %s\n' "$(report_path "$sm_id")"; else printf 'REPORT: unavailable\n'; fi
}
# JSON for the report: strings are escaped bytewise; < > & become \u escapes so the data cannot close the script block.
js_awk='BEGIN { for (i = 1; i < 32; i++) m[sprintf("%c", i)] = sprintf("\\u%04x", i); m["\""] = "\\\""; m["\\"] = "\\\\"; m["<"] = "\\u003c"; m[">"] = "\\u003e"; m["&"] = "\\u0026"; m["\177"] = "\\u007f"; printf "%s", (list ? "[" : "\"") }
{ o = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); o = o ((c in m) ? m[c] : c) }
  if (list) printf "%s\"%s\"", (NR > 1 ? "," : ""), o; else printf "%s%s", (NR > 1 ? "\\n" : ""), o }
END { printf "%s", (list ? "]" : "\"") }'
js() { printf '%s' "$1" | LC_ALL=C awk -v list=0 "$js_awk"; }                      # one string
jv() { if [ -n "$1" ]; then js "$1"; else printf null; fi; }                       # string or null
jl() { sed '/^$/d' | LC_ALL=C awk -v list=1 "$js_awk"; }                           # lines -> array of strings
joinc() { tr '\n' ',' | sed 's/,$//'; }
flow_item() { printf '{"stage":"%s","state":"%s"},' "$1" "$2"; }
gate_state() { gate_scan "$1" "$2"; case "$gs_r" in pass) echo done ;; fail) echo failed ;; *) echo pending ;; esac; }
report_run() {
  rp_id=$(projection_task "${1:-}") || return 1; rp_d=$(run_dir "$rp_id")
  rp_tpl=$root/.agents/skills/oversight-report/assets/report-template.html; [ -f "$rp_tpl" ] || fail "report template missing: ${rp_tpl#$root/}"
  rp_out=$(report_path "$rp_id"); rp_dir=$(report_dir)
  rp_par=$(CDPATH= cd "$(dirname "$rp_dir")" && pwd -P) || fail "temporary directory is not usable: ${TMPDIR:-/tmp}"; rp_top=$(CDPATH= cd "$root" && pwd -P)
  case "$rp_par/" in "$rp_top"/*) fail "refusing to write a report inside the repository: $rp_par" ;; esac
  [ ! -L "$rp_dir" ] || fail "refusing report directory: $rp_dir"
  mkdir -p -m 700 "$rp_dir" 2>/dev/null || true
  [ -d "$rp_dir" ] && [ ! -L "$rp_dir" ] || fail "could not create the report directory: $rp_dir"
  [ "$(ls -ldn "$rp_dir" | awk '{print $3}')" = "$(id -u)" ] || fail "refusing report directory not owned by you: $rp_dir"
  [ "$(ls -ld "$rp_dir" | cut -c1-10)" = drwx------ ] || chmod 700 "$rp_dir" 2>/dev/null || true
  [ "$(ls -ld "$rp_dir" | cut -c1-10)" = drwx------ ] || fail "report directory is not mode 700: $rp_dir"
  [ ! -L "$rp_out" ] && [ ! -d "$rp_out" ] || fail "refusing report target: $rp_out"
  find "$rp_dir" -maxdepth 1 -type f -name '*.html' -mtime +7 -exec rm -f {} + 2>/dev/null || true
  rp_hand=$(section_value "$rp_d" handoff state); rp_class=$(pipeline_class "$rp_id" | grep -v PENDING || true)
  rp_topo=$(resolve_topology "$rp_d" 2>/dev/null) || rp_topo=''
  rp_ed=$(worker_evidence_dir "$rp_id")
  rp_fz() { [ -n "$(section_value "$rp_d" freeze "$1")" ] && [ "$(section_value "$rp_d" freeze "$1")" != PENDING ]; }
  rp_flow=''
  rp_s=pending; if rp_fz plan_sha256; then rp_s=done; fi; rp_flow=$rp_flow$(flow_item discover "$rp_s")
  if [ "$(pipeline_needs "$rp_id" evidence)" = yes ]; then rp_s=pending; if rp_fz evidence_sha256; then rp_s=done; fi; rp_flow=$rp_flow$(flow_item evidence "$rp_s"); fi
  rp_s=pending; if rp_fz plan_sha256; then rp_s=done; fi; rp_flow=$rp_flow$(flow_item plan "$rp_s")
  case "$rp_hand" in IMPLEMENTING) rp_s=active ;; IMPLEMENTED|CODE_DONE|DONE) rp_s=done ;; *) rp_s=pending ;; esac; rp_flow=$rp_flow$(flow_item implement "$rp_s")
  for rp_g in $(pipeline_gates "$rp_id"); do rp_flow=$rp_flow$(flow_item "$(printf '%s' "$rp_g" | tr 'A-Z' 'a-z')" "$(gate_state "$rp_id" "$rp_g")"); done
  case "$rp_hand" in CODE_DONE|DONE) rp_s=done ;; *) rp_s=pending ;; esac; rp_flow=$rp_flow$(flow_item code_done "$rp_s")
  case "$(section_value "$rp_d" execution knowledge_state)" in not_started|'') rp_s=pending ;; not_applicable) rp_s=skipped ;; *) rp_s=done ;; esac; rp_flow=$rp_flow$(flow_item knowledge "$rp_s")
  if [ "$rp_hand" = DONE ]; then rp_s=done; else rp_s=pending; fi; rp_flow=$rp_flow$(flow_item done "$rp_s")
  case "$(run_state "$rp_d")" in FAILED|BLOCKED) rp_flow=$rp_flow$(flow_item outcome "$(run_state "$rp_d" | tr 'A-Z' 'a-z')") ;; esac
  rp_flow="[${rp_flow%,}]"
  # roles: recorded = named by a ledger entry, gate record or worker evidence; expected = what the pipeline and topology call for
  rp_rec=$( { sed -n 's/.* role=\([a-z_]*\) .*/\1/p' "$(ledger_file "$rp_id")" 2>/dev/null
    for rp_f in $(gate_names "$rp_id"); do gate_field "$(gates_dir "$rp_id")/$rp_f" role; done
    for rp_f in "$rp_ed"/*.yaml; do if [ -f "$rp_f" ]; then evidence_field "$rp_f" role; fi; done; } | sed '/^$/d' | sort -u)
  rp_exp=$( { expected_implementation_owner "$rp_topo" 2>/dev/null; for rp_g in $(pipeline_gates "$rp_id"); do gate_independent_role "$rp_g"; done; } | sort -u)
  rp_roles='['; rp_sep=''
  for rp_r in $(printf '%s\n%s\n' "$rp_rec" "$rp_exp" | sed '/^$/d' | sort -u); do
    if printf '%s\n' "$rp_rec" | grep -Fxq "$rp_r"; then rp_s=recorded; else rp_s=expected_no_record; fi
    rp_roles="$rp_roles$rp_sep{\"role\":$(js "$rp_r"),\"state\":\"$rp_s\"}"; rp_sep=,
  done; rp_roles=$rp_roles']'
  rp_att=''; for rp_g in $(pipeline_gates "$rp_id"); do gate_scan "$rp_id" "$rp_g"; rp_att="$rp_att${rp_att:+,}\"$(printf '%s' "$rp_g" | tr 'A-Z' 'a-z')\":$gs_n"; done
  rp_fnd='['; rp_sep=''; rp_open=''
  if rp_paths=$(changed_paths "$rp_id"); then rp_open=$(open_finding_seq "$rp_id" "$(task_patch_fingerprint "$rp_id")"); fi
  for rp_f in $(gate_names "$rp_id"); do
    rp_gf=$(gates_dir "$rp_id")/$rp_f; [ "$(gate_field "$rp_gf" result)" = fail ] || continue
    rp_fnd="$rp_fnd$rp_sep{\"gate\":$(js "$(gate_field "$rp_gf" gate)"),\"seq\":$(gate_field "$rp_gf" seq),\"open\":$([ "$(gate_field "$rp_gf" seq)" = "$rp_open" ] && echo true || echo false),\"text\":$(js "$(gate_field "$rp_gf" findings | cut -c1-300)"),\"fixScope\":$(gate_field "$rp_gf" fix_scope | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jl)}"; rp_sep=,
  done; rp_fnd=$rp_fnd']'
  rp_files=$(printf '%s\n' "${rp_paths:-}" | sed '/^$/d' | while IFS= read -r rp_p; do
    rp_nm=$(git -C "$root" diff --numstat HEAD -- "$rp_p" 2>/dev/null | head -1 | cut -f1,2)
    [ -n "$rp_nm" ] || rp_nm="$(wc -l < "$root/$rp_p" 2>/dev/null | tr -d ' ')	0"
    printf '{"path":%s,"add":%s,"del":%s}\n' "$(js "$rp_p")" "$(printf '%s' "$rp_nm" | cut -f1 | sed 's/^-$/null/;s/^$/null/')" "$(printf '%s' "$rp_nm" | cut -f2 | sed 's/^-$/null/;s/^$/null/')"
  done | joinc)
  rp_ver=$(sed -n 's/^- `\(.*\)` | exit=\([0-9][0-9]*\)[[:space:]]*$/\2 \1/p' "$rp_d/VERIFY.md" 2>/dev/null | while IFS=' ' read -r rp_c rp_cmd; do printf '{"command":%s,"exit":%s}\n' "$(js "$rp_cmd")" "$rp_c"; done | joinc)
  rp_ac=$(sed -n 's/^- \(AC-[0-9][0-9]*\): *\(.*\)$/\1|\2/p' "$rp_d/TASK.md" 2>/dev/null | while IFS='|' read -r rp_i rp_t; do printf '{"id":%s,"text":%s}\n' "$(js "$rp_i")" "$(js "$rp_t")"; done | joinc)
  rp_json=$(printf '{"task":{"id":%s,"title":%s},"status":{"run":%s,"handoff":%s,"knowledge":%s},"class":%s,"topology":%s,"flow":%s,"roles":%s,"attempts":{%s},"fixLoops":%s,"criteria":[%s],"files":[%s],"findings":%s,"verification":[%s]}' \
    "$(js "$rp_id")" "$(jv "$(sed -n '1s/^#[[:space:]]*//p' "$rp_d/TASK.md" 2>/dev/null)")" "$(jv "$(run_state "$rp_d")")" "$(jv "$rp_hand")" "$(jv "$(section_value "$rp_d" execution knowledge_state)")" "$(jv "$rp_class")" "$(jv "$rp_topo")" \
    "$rp_flow" "$rp_roles" "$rp_att" "$(fix_cycles_used "$rp_id")" "$rp_ac" "$rp_files" "$rp_fnd" "$rp_ver")
  rp_jf=$(mktemp "$rp_dir/.report.XXXXXX") || fail "could not create a report file in $rp_dir"
  rp_tmp=$(mktemp "$rp_dir/.report.XXXXXX") || { rm -f "$rp_jf"; fail "could not create a report file in $rp_dir"; }
  printf '%s\n' "$rp_json" > "$rp_jf"
  if RP_DATA=$rp_jf awk '$0 == "__OVERSIGHT_DATA__" { while ((r = (getline l < ENVIRON["RP_DATA"])) > 0) { print l; n++ } if (r < 0 || !n) bad = 1; next } { print } END { exit bad }' "$rp_tpl" > "$rp_tmp" && mv -f "$rp_tmp" "$rp_out"; then rm -f "$rp_jf"; printf 'report: %s\n' "$rp_out"
  else rm -f "$rp_tmp" "$rp_jf"; fail "could not write the report"; fi
}

knowledge_done() {
  id=$1 state=${2:-KNOWLEDGE_DONE}; require_run "$id"; dir=$(run_dir "$id"); require_full_lifecycle; require_open_run "$id"
  case "$state" in KNOWLEDGE_DONE|not_applicable) ;; *) fail "invalid knowledge state: $state" ;; esac
  [ "$(run_state "$dir")" = CODE_DONE ] || fail "knowledge-done requires CODE_DONE first"
  section_key_present "$dir" execution knowledge_state || fail "run schema has no execution.knowledge_state field to set"
  verify_seal "$id"
  ! local_task_source_run "$id" || verify_freshness "$id" >/dev/null
  tmp=$dir/RUN.yaml.tmp; replace_section_value "$dir" execution knowledge_state "$state" "$tmp" && mv "$tmp" "$dir/RUN.yaml"
  if gates_enforced "$id"; then ledger_append "$id" knowledge-done "$(section_value "$dir" handoff state)" "$state" ""; fi
  workflow_event "$id" --event stage --stage knowledge --status "$([ "$state" = not_applicable ] && echo skipped || echo completed)"
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

# $2 (default: 0/strict) — when 1, a path under `knowledge_scope_root` is
# treated as out of *application* scope (neither pass nor fail here) instead
# of "unexpected", and is deferred entirely to `verify_knowledge_scope`. This
# is only ever passed as 1 for the DONE handoff transition (see
# record_handoff) — every other caller (the `verify-scope` CLI command,
# `delivery_check`, `verify_handoff`, and every pre-DONE handoff phase) keeps
# the original strict behavior unchanged, so a knowledge-scope write attempted
# before CODE_DONE is still flagged exactly as before this option existed.
verify_scope() {
  id=$1 allow_knowledge=${2:-0}; require_run "$id"; dir=$(run_dir "$id"); enforce_task_branch "$id"; mappings=$(scope_mappings "$dir/PLAN.md") || fail "invalid scope mapping"; [ -n "$mappings" ] || fail "scope mapping missing"
  status=$(baseline_status "$dir"); [ "$status" = captured ] || fail "baseline required before scope verification: $id"
  # Runs are gitignored, so git cannot see a stray file in the run directory: check it directly.
  validate_control_artifacts "$id"
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-scope.XXXXXX")
  for type in tracked untracked; do
    paths=$( [ "$type" = tracked ] && current_tracked_paths || current_untracked_paths )
    printf '%s\n' "$paths" | while IFS= read -r changed; do
      [ -n "$changed" ] || continue
      known_control_artifact "$id" "$changed" && continue
      task_source_bookkeeping_only "$id" "$changed" && continue
      if [ "$allow_knowledge" = 1 ] && in_knowledge_scope "$changed"; then continue; fi
      prior=$(baseline_fingerprint "$type" "$changed" "$dir"); current=$(fingerprint_path "$changed")
      if [ -n "$prior" ] && [ "$prior" = "$current" ]; then continue; fi
      authorized_path "$mappings" "$changed" || printf '%s\n' "$changed" >> "$tmp"
    done
  done
  unexpected=$(cat "$tmp"); rm "$tmp"
  [ -z "$unexpected" ] || { echo "unexpected or unmapped task-introduced paths:" >&2; printf '%s\n' "$unexpected" >&2; return 1; }; echo "scope check passed: $id"
}

# The Transaction B counterpart to verify_scope: validates every changed path
# that *is* under `knowledge_scope_root`, independently of application scope.
# A knowledge-scope diff is only legitimate when `execution.knowledge_state`
# is recorded `KNOWLEDGE_DONE` (real writes happened and the transaction was
# closed out) or the diff set is empty while it is `not_applicable` (no writes
# were needed and none happened) — every other combination fails closed:
# diffs present without a recorded-complete transaction, or a transaction
# claimed complete with zero diffs to show for it (`not_applicable` is the
# correct value for that case, not `KNOWLEDGE_DONE`).
verify_knowledge_scope() {
  id=$1; require_run "$id"; dir=$(run_dir "$id")
  status=$(baseline_status "$dir"); [ "$status" = captured ] || fail "baseline required before knowledge-scope verification: $id"
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-knowledge-scope.XXXXXX")
  for type in tracked untracked; do
    paths=$( [ "$type" = tracked ] && current_tracked_paths || current_untracked_paths )
    printf '%s\n' "$paths" | while IFS= read -r changed; do
      [ -n "$changed" ] || continue
      known_control_artifact "$id" "$changed" && continue
      in_knowledge_scope "$changed" || continue
      prior=$(baseline_fingerprint "$type" "$changed" "$dir"); current=$(fingerprint_path "$changed")
      if [ -n "$prior" ] && [ "$prior" = "$current" ]; then continue; fi
      printf '%s\n' "$changed" >> "$tmp"
    done
  done
  owned=$(cat "$tmp"); rm -f "$tmp"
  ks=$(section_value "$dir" execution knowledge_state)
  if [ -n "$owned" ]; then
    case "$ks" in
      KNOWLEDGE_DONE) ;;
      *) echo "knowledge-scope changes present but knowledge transaction not recorded complete (knowledge_state=$ks); run 'agent.sh knowledge-done' first, or these paths are unauthorized:" >&2; printf '%s\n' "$owned" >&2; return 1 ;;
    esac
  else
    case "$ks" in
      KNOWLEDGE_DONE) fail "knowledge_state is KNOWLEDGE_DONE but no knowledge-scope changes were found under $(knowledge_scope_root) — record 'not_applicable' instead if no writes were needed" ;;
    esac
  fi
  echo "knowledge scope verified: $id"
}

freeze() {
  id=$1; require_run "$id"; dir=$(run_dir "$id"); for f in TASK.md PLAN.md RUN.yaml; do [ -f "$dir/$f" ] || fail "missing $f"; done
  require_open_run "$id"; pipeline_check "$id"
  [ "$(run_state "$dir")" != CODE_DONE ] || fail "cannot freeze completed run: $id"; [ "$(baseline_status "$dir")" = captured ] || fail "baseline required before freeze: $id"
  enforce_task_branch "$id"
  verify_seal "$id"
  verify_task_source_status "$id"
  if freeze_hash_present "$dir"; then
    [ "${2:-}" = refreeze ] && [ -n "${3:-}" ] || fail "existing freeze requires explicit amendment"
    case "$3" in */*|*..*) fail "invalid amendment name: $3" ;; esac
    [ -f "$dir/amendments/$3" ] || fail "existing freeze requires explicit amendment"
    # One amendment authorizes one refreeze: reusing an amendment file would let a run escape the bounded fix budget.
    ! grep -Fq "event=refreeze " "$(ledger_file "$id")" 2>/dev/null || ! grep -F "event=refreeze " "$(ledger_file "$id")" | grep -Fq "detail=amendment $3" || fail "amendment $3 was already used for a refreeze; write a new amendment"
  fi
  tmp=$dir/RUN.yaml.tmp; replace_hashes "$dir" "$tmp"
  if freeze_hash_present "$dir" && gates_enforced "$id"; then
    [ "$(sed -n '/^freeze:$/,/^[^ ]/p' "$dir/RUN.yaml")" != "$(sed -n '/^freeze:$/,/^[^ ]/p' "$tmp")" ] || { rm -f "$tmp"; fail "refreeze changes nothing: an amendment must change the task, evidence, plan, QA plan or classification"; }
  fi
  mv "$tmp" "$dir/RUN.yaml"; set_task_source_revision "$dir"
  if gates_enforced "$id"; then
    if [ "${2:-}" = refreeze ]; then refreeze_lifecycle "$id" "${3:-}"
    else ledger_append "$id" freeze "$(section_value "$dir" handoff state)" "$(section_value "$dir" handoff state)" "$(section_value "$dir" freeze pipeline)"; fi
  fi
  if [ "$(pipeline_needs "$id" evidence)" = yes ]; then workflow_event "$id" --event stage --stage evidence --status completed; fi
  workflow_event "$id" --event stage --stage plan --status completed
  echo "freeze recorded: $id"
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
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/FIX.md' '  revision: PENDING' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/FIX/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email fixture@example.invalid; git config user.name fixture; : > authorized.txt; : > user-dirty.txt; printf '# canonical task\n' > tasks/FIX.md; git add -- .agents scripts docs tasks authorized.txt user-dirty.txt; git commit -qm baseline
    printf 'user work\n' > user-dirty.txt; : > user-untracked.txt; ./scripts/agent.sh baseline FIX; printf 'discovered\n' >> .agents/runs/FIX/EVIDENCE.md; printf 'planned\n' >> .agents/runs/FIX/PLAN.md; ./scripts/agent.sh verify-scope FIX; ./scripts/agent.sh freeze FIX; ./scripts/agent.sh verify-freeze FIX; ./scripts/agent.sh freshness FIX; if ./scripts/agent.sh handoff FIX IMPLEMENTED; then exit 1; fi; cp tasks/FIX.md "$scratch/task-source.original"; printf 'changed source\n' >> tasks/FIX.md; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/task-source.original" tasks/FIX.md; mv tasks/FIX.md "$scratch/task-source.missing"; if ./scripts/agent.sh freshness FIX; then exit 1; fi; mv "$scratch/task-source.missing" tasks/FIX.md; cp .agents/runs/FIX/RUN.yaml "$scratch/source-run.original"; sed 's#path: tasks/FIX.md#path: ../outside.md#' "$scratch/source-run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/source-run.original" .agents/runs/FIX/RUN.yaml; cp .agents/runs/FIX/TASK.md "$scratch/task-contract.original"; printf 'changed contract\n' >> .agents/runs/FIX/TASK.md; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; cp "$scratch/task-contract.original" .agents/runs/FIX/TASK.md; ./scripts/agent.sh handoff FIX IMPLEMENTING; if ./scripts/agent.sh handoff FIX CODE_DONE; then exit 1; fi; ./scripts/agent.sh verify-handoff FIX; ./scripts/agent.sh validate FIX; cp .agents/runs/FIX/RUN.yaml "$scratch/run.original"; sed 's/base_sha: ".*"/base_sha: "PENDING"/' "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh validate FIX; then exit 1; fi; cp "$scratch/run.original" .agents/runs/FIX/RUN.yaml; sed 's/revision: ".*"/revision: "changed"/' "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; if ./scripts/agent.sh freshness FIX; then exit 1; fi; cp "$scratch/run.original" .agents/runs/FIX/RUN.yaml; cp .agents/modes/deterministic.yaml "$scratch/policy.original"; printf '\n# changed\n' >> .agents/modes/deterministic.yaml; if ./scripts/agent.sh verify-freeze FIX; then exit 1; fi; mv "$scratch/policy.original" .agents/modes/deterministic.yaml
    git commit --allow-empty -qm planning-source-advanced; if ./scripts/agent.sh freshness FIX; then exit 1; fi; sed "s/base_sha: \".*\"/base_sha: \"$(git rev-parse HEAD)\"/" "$scratch/run.original" > .agents/runs/FIX/RUN.yaml; mkdir -p .agents/runs/FIX/amendments; printf '# amendment\n' > .agents/runs/FIX/amendments/001.md; ./scripts/agent.sh refreeze FIX 001.md; ./scripts/agent.sh freshness FIX; cp .agents/runs/FIX/RUN.yaml "$scratch/source.original"; sed 's/type: local_markdown/type: none/; s/revision: ".*"/revision: not_applicable/' "$scratch/source.original" > .agents/runs/FIX/RUN.yaml; ./scripts/agent.sh freshness FIX; mv "$scratch/source.original" .agents/runs/FIX/RUN.yaml
    ./scripts/agent.sh verify-scope FIX
    printf 'agent touched dirty path\n' >> user-dirty.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; git checkout -- user-dirty.txt; printf 'user work\n' > user-dirty.txt
    printf 'agent touched untracked path\n' >> user-untracked.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; : > user-untracked.txt
    printf 'change\n' > authorized.txt; ./scripts/agent.sh verify-scope FIX; printf 'unexpected\n' > unexpected.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; rm unexpected.txt
    printf 'random\n' > .agents/runs/FIX/random.txt; if ./scripts/agent.sh verify-scope FIX; then exit 1; fi; if ./scripts/agent.sh validate FIX; then exit 1; fi; rm .agents/runs/FIX/random.txt
    ./scripts/agent.sh handoff FIX IMPLEMENTED; ./scripts/agent.sh verify-handoff FIX; printf 'again\n' >> authorized.txt; if ./scripts/agent.sh handoff FIX CODE_DONE; then exit 1; fi; if ./scripts/agent.sh verify-handoff FIX; then exit 1; fi; ./scripts/agent.sh handoff FIX IMPLEMENTED; ./scripts/agent.sh verify-handoff FIX; ./scripts/agent.sh handoff FIX CODE_DONE; ./scripts/agent.sh delivery-check FIX; if ./scripts/agent.sh handoff FIX IMPLEMENTED; then exit 1; fi; printf 'post-review\n' >> authorized.txt; if ./scripts/agent.sh delivery-check FIX; then exit 1; fi; printf 'unauthorized\n' > delivery-unexpected.txt; if ./scripts/agent.sh delivery-check FIX; then exit 1; fi; rm delivery-unexpected.txt
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
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: none' '  revision: not_applicable' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/ROLE/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email role@example.invalid; git config user.name fixture; : > authorized.txt; git add -- .agents scripts authorized.txt; git commit -qm baseline
    ./scripts/agent.sh role | grep -Fxq 'role=full_lifecycle'; AGENT_ROLE=full_lifecycle ./scripts/agent.sh role | grep -Fxq 'role=full_lifecycle'
    ./scripts/agent.sh baseline ROLE; ./scripts/agent.sh freeze ROLE; printf 'implementation\n' >> authorized.txt
    AGENT_ROLE=implementation_worker ./scripts/agent.sh role | grep -Fxq 'role=implementation_worker'; AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope ROLE; AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE IMPLEMENTING
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE IMPLEMENTED; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh handoff ROLE CODE_DONE; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh freeze ROLE; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh refreeze ROLE 001.md; then exit 1; fi; if AGENT_ROLE=implementation_worker ./scripts/agent.sh delivery-check ROLE; then exit 1; fi
    ./scripts/agent.sh handoff ROLE IMPLEMENTED
    printf 'unplanned\n' > unplanned.txt; if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope ROLE; then exit 1; fi)
  echo 'agent role tests passed'
}

# Proves the worker-evidence / TDD / completion-report enforcement under
# execution.topology: orchestrated: a full_lifecycle orchestrator cannot
# silently implement application code and advance past IMPLEMENT (the
# bypass this policy closes), evidence is bound to the current task/freeze
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
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/POLICY/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email policy@example.invalid; git config user.name fixture
    printf '# POLICY task\n' > tasks/POLICY.md; : > impl.txt; : > config.txt
    git add -- .agents scripts tasks impl.txt config.txt; git commit -qm baseline

    ./scripts/agent.sh baseline POLICY
    printf 'discovered\n' >> .agents/runs/POLICY/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/POLICY/PLAN.md
    ./scripts/agent.sh freeze POLICY
    ./scripts/agent.sh handoff POLICY IMPLEMENTING

    # A full_lifecycle session implements the change directly (the bypass
    # this test guards against) and then tries to advance the lifecycle as though
    # delegation had occurred. This must be rejected: no worker evidence
    # exists yet for either scope path.
    printf 'implemented directly by full_lifecycle\n' > impl.txt
    if ./scripts/agent.sh handoff POLICY IMPLEMENTED; then echo "FAIL: full_lifecycle bypass was not rejected" >&2; exit 1; fi
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
    if ./scripts/agent.sh handoff POLICY IMPLEMENTED; then echo "FAIL: IMPLEMENTED allowed with GREEN but no valid RED" >&2; exit 1; fi

    # A genuine RED (fails for a specific, named behavioral reason) plus the
    # GREEN already recorded above now satisfies impl.txt; config.txt is
    # covered by its validated tdd_exemption. IMPLEMENTED must now succeed.
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\nexpected_failure: TestImpl fails: registry returns zero tasks before the new lookup method exists\n' | ./scripts/agent.sh worker-evidence POLICY RED fail"
    ./scripts/agent.sh handoff POLICY IMPLEMENTED

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
      'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
      'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
      'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
      > .agents/runs/POLICY2/RUN.yaml
    printf 'POLICY2\n' > .agents/ACTIVE_RUN
    ./scripts/agent.sh baseline POLICY2; printf 'discovered\n' >> .agents/runs/POLICY2/EVIDENCE.md; printf 'planned\n' >> .agents/runs/POLICY2/PLAN.md; ./scripts/agent.sh freeze POLICY2
    ./scripts/agent.sh handoff POLICY2 IMPLEMENTING
    mkdir -p .agents/runs/POLICY2/worker-evidence
    cp .agents/runs/POLICY/worker-evidence/GREEN-1.yaml .agents/runs/POLICY2/worker-evidence/GREEN-1.yaml
    cp .agents/runs/POLICY/worker-evidence/RED-1.yaml .agents/runs/POLICY2/worker-evidence/RED-1.yaml
    if ./scripts/agent.sh handoff POLICY2 IMPLEMENTED; then echo "FAIL: cross-task evidence (wrong task_id/hashes) was accepted" >&2; exit 1; fi
    printf 'POLICY\n' > .agents/ACTIVE_RUN)
  echo 'agent policy tests passed'
}

# Regression test for the worker-evidence sandbox failure: `codex
# exec --sandbox workspace-write` denied writes under the run's own
# `.agents/runs/<ID>/worker-evidence/` directory, and record_worker_evidence
# printed a false "recorded" success message instead of failing closed.
# Permissions simulate the same denied-write effect deterministically,
# without depending on a real sandboxed `codex` subprocess.
worker_evidence_write_failure_test() {
  tmp=$(mktemp -d /tmp/deterministic-writefail.XXXXXX); trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/WRITEFAIL/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  printf 'WRITEFAIL\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: WRITEFAIL\n' > "$tmp/.agents/runs/WRITEFAIL/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/WRITEFAIL/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/WRITEFAIL/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/WRITEFAIL.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/WRITEFAIL/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email writefail@example.invalid; git config user.name fixture
    printf '# WRITEFAIL task\n' > tasks/WRITEFAIL.md; : > impl.txt
    git add -- .agents scripts tasks impl.txt; git commit -qm baseline
    ./scripts/agent.sh baseline WRITEFAIL
    printf 'discovered\n' >> .agents/runs/WRITEFAIL/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/WRITEFAIL/PLAN.md
    ./scripts/agent.sh freeze WRITEFAIL
    ./scripts/agent.sh handoff WRITEFAIL IMPLEMENTING

    # The run's worker-evidence directory exists but cannot be written to —
    # this is the deterministic stand-in for the sandbox denying the write.
    mkdir -p .agents/runs/WRITEFAIL/worker-evidence
    chmod 555 .agents/runs/WRITEFAIL/worker-evidence

    if err_out=$(printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: lookup method does not exist yet, specifically\n' | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence WRITEFAIL RED fail 2>&1); then
      chmod 755 .agents/runs/WRITEFAIL/worker-evidence
      echo "FAIL: worker-evidence command succeeded (exit 0) despite a denied directory write" >&2; exit 1
    fi
    chmod 755 .agents/runs/WRITEFAIL/worker-evidence
    printf '%s\n' "$err_out" | grep -qi "worker evidence" || { echo "FAIL: failure message did not mention worker evidence: $err_out" >&2; exit 1; }
    printf '%s\n' "$err_out" | grep -qi "recorded" && { echo "FAIL: a denied write must not print a success-sounding 'recorded' message: $err_out" >&2; exit 1; }
    [ -z "$(ls -A .agents/runs/WRITEFAIL/worker-evidence 2>/dev/null)" ] || { echo "FAIL: a partial/empty evidence file was left behind after a denied write" >&2; exit 1; }

    # Once the directory is writable again (the fix: scripts/worker-run.sh
    # passing --add-dir for exactly this directory), the identical command
    # succeeds and leaves a real, non-empty, well-formed evidence file.
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: lookup method does not exist yet, specifically\n' | ./scripts/agent.sh worker-evidence WRITEFAIL RED fail"
    [ -s .agents/runs/WRITEFAIL/worker-evidence/RED-1.yaml ] || { echo "FAIL: evidence file missing/empty after a successful write" >&2; exit 1; }
    grep -q '^task_id: "WRITEFAIL"' .agents/runs/WRITEFAIL/worker-evidence/RED-1.yaml || { echo "FAIL: evidence file content malformed" >&2; exit 1; })
  echo 'agent worker-evidence write-failure tests passed'
}

# Regression test for the DONE-transition failure: a legitimate
# Transaction B (knowledge transaction) write under docs/wiki/** was rejected by DONE's
# scope check as an "unexpected or unmapped task-introduced path", because
# verify_scope only ever recognized PLAN.md's frozen application scope.
# Proves: (1) a knowledge-scope diff without a recorded-complete knowledge
# transaction still fails closed; (2) an application-scope violation is still
# rejected at DONE regardless of knowledge-scope state (no loophole); (3) a
# knowledge-scope diff with knowledge_state=not_applicable (mismatched) still
# fails closed; (4) a genuine knowledge-scope diff with knowledge_state=
# KNOWLEDGE_DONE now legitimately reaches DONE; (5) knowledge_state=
# KNOWLEDGE_DONE with zero actual knowledge-scope diffs fails closed
# (prevents the value being rubber-stamped without real writes).
knowledge_scope_test() {
  tmp=$(mktemp -d /tmp/deterministic-knowscope.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/KNOWSCOPE/review" "$tmp/.agents/modes" "$tmp/.agents/task-integrations" "$tmp/scripts" "$tmp/tasks" "$tmp/docs/wiki"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  cp "$root/.agents/task-integrations/markdown.sh" "$tmp/.agents/task-integrations/"; chmod +x "$tmp/.agents/task-integrations/markdown.sh"
  printf 'KNOWSCOPE\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: KNOWSCOPE\n' > "$tmp/.agents/runs/KNOWSCOPE/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/KNOWSCOPE/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/KNOWSCOPE/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/KNOWSCOPE.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/KNOWSCOPE/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email knowscope@example.invalid; git config user.name fixture
    printf '# KNOWSCOPE task\n' > tasks/KNOWSCOPE.md; : > impl.txt; printf '# Wiki index\n' > docs/wiki/index.md
    git add -- .agents scripts tasks impl.txt docs/wiki; git commit -qm baseline

    ./scripts/agent.sh baseline KNOWSCOPE
    printf 'discovered\n' >> .agents/runs/KNOWSCOPE/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/KNOWSCOPE/PLAN.md
    ./scripts/agent.sh freeze KNOWSCOPE
    ./scripts/agent.sh handoff KNOWSCOPE IMPLEMENTING
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: Find() does not exist yet, specifically\n' | ./scripts/agent.sh worker-evidence KNOWSCOPE RED fail"
    printf 'implemented\n' > impl.txt
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence KNOWSCOPE GREEN pass"
    ./scripts/agent.sh handoff KNOWSCOPE IMPLEMENTED
    ./scripts/agent.sh handoff KNOWSCOPE CODE_DONE

    # (1) A real application-scope violation is still rejected at DONE, with
    # zero knowledge-scope diffs in the picture at all — the knowledge-scope
    # mechanism does not relax application-scope enforcement.
    printf 'rogue application edit\n' > rogue.txt
    if ./scripts/agent.sh handoff KNOWSCOPE DONE; then echo "FAIL: an unmapped application-scope path was accepted at DONE" >&2; exit 1; fi
    rm -f rogue.txt

    # (2) A knowledge-scope (docs/wiki/**) diff with no recorded-complete
    # knowledge transaction still fails closed — this is the exact shape of
    # writing to the vault without ever calling `knowledge-done`.
    printf '# Lesson\n' > docs/wiki/lesson.md
    if ./scripts/agent.sh handoff KNOWSCOPE DONE; then echo "FAIL: a knowledge-scope diff was accepted at DONE without a recorded knowledge transaction" >&2; exit 1; fi

    # (3) Recording the knowledge transaction as `not_applicable` while a
    # real knowledge-scope diff exists is a mismatch, not a bypass — still
    # rejected. `not_applicable` must mean "no writes happened", not "any
    # writes are pre-approved".
    ./scripts/agent.sh knowledge-done KNOWSCOPE not_applicable
    if ./scripts/agent.sh handoff KNOWSCOPE DONE; then echo "FAIL: knowledge_state=not_applicable was accepted despite a real knowledge-scope diff" >&2; exit 1; fi

    # (4) The corrected, legitimate case: the knowledge transaction actually
    # happened and is recorded KNOWLEDGE_DONE — this is the scenario the
    # test guards. verify-knowledge-scope reports success directly, and DONE
    # (once the completion report is published/verified, matching every
    # other run's DONE gate) now legitimately succeeds.
    ./scripts/agent.sh knowledge-done KNOWSCOPE KNOWLEDGE_DONE
    ./scripts/agent.sh verify-knowledge-scope KNOWSCOPE
    printf '%s\n' '# Completion Report: KNOWSCOPE' '' '## Implementation Summary' 'impl.txt gained Find().' '' \
      '## TDD Evidence' 'RED failed for the expected reason; GREEN passed.' '' '## Verification' 'go test ./... passed.' '' \
      '## Review Result' 'Approved.' '' '## Known Limitations / Follow-up' 'None.' \
      > .agents/runs/KNOWSCOPE/COMPLETION_REPORT.md
    ./scripts/agent.sh publish-completion-report KNOWSCOPE markdown
    ./scripts/agent.sh verify-completion-report KNOWSCOPE
    ./scripts/agent.sh handoff KNOWSCOPE DONE

    # (5) Consistency check: knowledge_state=KNOWLEDGE_DONE with zero actual
    # knowledge-scope diffs is itself rejected — a run cannot claim the
    # transaction happened with nothing to show for it (use `not_applicable`
    # for that case instead). Removing the only knowledge-scope diff and
    # re-running the (idempotent, DONE->DONE) handoff proves this.
    rm -f docs/wiki/lesson.md
    if ./scripts/agent.sh handoff KNOWSCOPE DONE; then echo "FAIL: knowledge_state=KNOWLEDGE_DONE with zero knowledge-scope diffs was accepted" >&2; exit 1; fi)
  echo 'agent knowledge-scope tests passed'
}

# Regression test for the delivery-check failure: DONE correctly accepted
# a legitimate knowledge transaction, but `agent.sh delivery-check` (called
# afterward, as a delivery attempt is) still ran the strict, knowledge-blind
# `verify_scope`/`verify_handoff` and rejected the same already-accepted
# `docs/wiki/**` diff as an unexpected application-scope path. Proves the full
# sequence — CODE_DONE -> KNOWLEDGE_DONE with a legitimate wiki
# change -> DONE -> delivery-check succeeds — plus that delivery-check still
# fails closed on an unauthorized application change and on an invalid/
# inconsistent knowledge-transaction state, exactly like DONE does.
delivery_check_knowledge_scope_test() {
  tmp=$(mktemp -d /tmp/deterministic-deliveryknow.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/DELIVERKNOW/review" "$tmp/.agents/modes" "$tmp/.agents/task-integrations" "$tmp/scripts" "$tmp/tasks" "$tmp/docs/wiki"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  cp "$root/.agents/task-integrations/markdown.sh" "$tmp/.agents/task-integrations/"; chmod +x "$tmp/.agents/task-integrations/markdown.sh"
  printf 'DELIVERKNOW\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: DELIVERKNOW\n' > "$tmp/.agents/runs/DELIVERKNOW/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/DELIVERKNOW/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/DELIVERKNOW/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/DELIVERKNOW.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/DELIVERKNOW/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email deliverknow@example.invalid; git config user.name fixture
    printf '# DELIVERKNOW task\n' > tasks/DELIVERKNOW.md; : > impl.txt; printf '# Wiki index\n' > docs/wiki/index.md
    git add -- .agents scripts tasks impl.txt docs/wiki; git commit -qm baseline

    ./scripts/agent.sh baseline DELIVERKNOW
    printf 'discovered\n' >> .agents/runs/DELIVERKNOW/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/DELIVERKNOW/PLAN.md
    ./scripts/agent.sh freeze DELIVERKNOW
    ./scripts/agent.sh handoff DELIVERKNOW IMPLEMENTING
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: Find() does not exist yet, specifically\n' | ./scripts/agent.sh worker-evidence DELIVERKNOW RED fail"
    printf 'implemented\n' > impl.txt
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence DELIVERKNOW GREEN pass"
    ./scripts/agent.sh handoff DELIVERKNOW IMPLEMENTED
    ./scripts/agent.sh handoff DELIVERKNOW CODE_DONE

    # Pre-knowledge-transaction: delivery-check already succeeds at plain
    # CODE_DONE (unchanged prior behavior — no knowledge-scope diff exists
    # yet, so verify_knowledge_scope has nothing to object to).
    ./scripts/agent.sh delivery-check DELIVERKNOW

    # (1) An unauthorized application-scope change still fails delivery-check
    # closed, regardless of knowledge-transaction state — the knowledge-scope
    # mechanism never relaxes application-scope enforcement.
    printf 'rogue application edit\n' > rogue.txt
    if ./scripts/agent.sh delivery-check DELIVERKNOW; then echo "FAIL: delivery-check accepted an unmapped application-scope path" >&2; exit 1; fi
    rm -f rogue.txt

    # (2) A knowledge-scope diff with no recorded-complete transaction still
    # fails delivery-check closed.
    printf '# Lesson\n' > docs/wiki/lesson.md
    if ./scripts/agent.sh delivery-check DELIVERKNOW; then echo "FAIL: delivery-check accepted a knowledge-scope diff with no recorded transaction" >&2; exit 1; fi

    # (3) A mismatched not_applicable (real diff present) still fails
    # delivery-check closed.
    ./scripts/agent.sh knowledge-done DELIVERKNOW not_applicable
    if ./scripts/agent.sh delivery-check DELIVERKNOW; then echo "FAIL: delivery-check accepted knowledge_state=not_applicable despite a real diff" >&2; exit 1; fi

    # (4) The sequence this test guards: a legitimate knowledge transaction is
    # recorded KNOWLEDGE_DONE, the completion report is published/verified,
    # DONE is reached — and delivery-check, run *afterward*, now succeeds
    # instead of re-rejecting the same diff DONE already accepted.
    ./scripts/agent.sh knowledge-done DELIVERKNOW KNOWLEDGE_DONE
    printf '%s\n' '# Completion Report: DELIVERKNOW' '' '## Implementation Summary' 'impl.txt gained Find().' '' \
      '## TDD Evidence' 'RED failed for the expected reason; GREEN passed.' '' '## Verification' 'go test ./... passed.' '' \
      '## Review Result' 'Approved.' '' '## Known Limitations / Follow-up' 'None.' \
      > .agents/runs/DELIVERKNOW/COMPLETION_REPORT.md
    ./scripts/agent.sh publish-completion-report DELIVERKNOW markdown
    ./scripts/agent.sh verify-completion-report DELIVERKNOW
    ./scripts/agent.sh handoff DELIVERKNOW DONE
    ./scripts/agent.sh delivery-check DELIVERKNOW

    # (5) Consistency still holds post-DONE: removing the only knowledge-scope
    # diff while knowledge_state stays KNOWLEDGE_DONE fails delivery-check
    # closed (same zero-diff-but-claimed-complete rejection DONE itself uses).
    rm -f docs/wiki/lesson.md
    if ./scripts/agent.sh delivery-check DELIVERKNOW; then echo "FAIL: delivery-check accepted KNOWLEDGE_DONE with zero knowledge-scope diffs" >&2; exit 1; fi)
  echo 'agent delivery-check knowledge-scope tests passed'
}

# Regression test for the `agent.sh validate` failure: unlike DONE
# and delivery-check (both independently fixed to run verify_scope/
# verify_handoff with allow_knowledge=1 plus verify_knowledge_scope for a
# legitimate Transaction B), `validate` still called verify_handoff in
# strict/default mode, so a knowledge transaction DONE and delivery-check
# had both already accepted would still fail validate with "unexpected or
# unmapped task-introduced paths" naming every docs/wiki/** path — pure
# knowledge-blindness in one specific caller, not a real scope violation.
# Proves the same five-case symmetry as delivery_check_knowledge_scope_test,
# this time against `validate`: (1) an application-scope violation still
# fails validate closed; (2) a knowledge-scope diff with no recorded
# transaction still fails closed; (3) a mismatched not_applicable still
# fails closed; (4) a genuine KNOWLEDGE_DONE transaction now legitimately
# passes validate, both before and after the DONE handoff transition;
# (5) KNOWLEDGE_DONE with zero actual knowledge-scope diffs still fails
# closed. Also confirms validate's pre-existing, unrelated behavior is
# untouched: it still requires COMPLETION_REPORT.md up front when
# completion_report.required is true, and it still succeeds with zero
# knowledge-scope diffs at all (the common case, unaffected by this fix).
validate_knowledge_scope_test() {
  tmp=$(mktemp -d /tmp/deterministic-validateknow.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.agents/runs/VALIDATEKNOW/review" "$tmp/.agents/modes" "$tmp/.agents/task-integrations" "$tmp/scripts" "$tmp/tasks" "$tmp/docs/wiki"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  cp "$root/.agents/task-integrations/markdown.sh" "$tmp/.agents/task-integrations/"; chmod +x "$tmp/.agents/task-integrations/markdown.sh"
  printf 'VALIDATEKNOW\n' > "$tmp/.agents/ACTIVE_RUN"
  printf '# Task: VALIDATEKNOW\n' > "$tmp/.agents/runs/VALIDATEKNOW/TASK.md"
  printf '# Evidence\n' > "$tmp/.agents/runs/VALIDATEKNOW/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/VALIDATEKNOW/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/VALIDATEKNOW.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: orchestrated' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/VALIDATEKNOW/RUN.yaml"
  (cd "$tmp"; git init -q; git config user.email validateknow@example.invalid; git config user.name fixture
    printf '# VALIDATEKNOW task\n' > tasks/VALIDATEKNOW.md; : > impl.txt; printf '# Wiki index\n' > docs/wiki/index.md
    git add -- .agents scripts tasks impl.txt docs/wiki; git commit -qm baseline

    ./scripts/agent.sh baseline VALIDATEKNOW
    printf 'discovered\n' >> .agents/runs/VALIDATEKNOW/EVIDENCE.md
    printf 'planned\n' >> .agents/runs/VALIDATEKNOW/PLAN.md
    ./scripts/agent.sh freeze VALIDATEKNOW
    ./scripts/agent.sh handoff VALIDATEKNOW IMPLEMENTING
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\nexpected_failure: TestImpl fails: Find() does not exist yet, specifically\n' | ./scripts/agent.sh worker-evidence VALIDATEKNOW RED fail"
    printf 'implemented\n' > impl.txt
    AGENT_ROLE=implementation_worker sh -c "printf 'command: go test ./...\ntarget: impl.txt\n' | ./scripts/agent.sh worker-evidence VALIDATEKNOW GREEN pass"
    ./scripts/agent.sh handoff VALIDATEKNOW IMPLEMENTED
    ./scripts/agent.sh handoff VALIDATEKNOW CODE_DONE

    # Publish the completion report right after CODE_DONE (before any
    # knowledge-scope diff exists), matching publish_completion_report's own
    # requirement (CODE_DONE only, independent of knowledge_state) and so
    # every `validate` call below passes the artifact-presence check and
    # actually exercises the knowledge-scope logic under test, not an
    # unrelated missing-file failure.
    printf '%s\n' '# Completion Report: VALIDATEKNOW' '' '## Implementation Summary' 'impl.txt gained Find().' '' \
      '## TDD Evidence' 'RED failed for the expected reason; GREEN passed.' '' '## Verification' 'go test ./... passed.' '' \
      '## Review Result' 'Approved.' '' '## Known Limitations / Follow-up' 'None.' \
      > .agents/runs/VALIDATEKNOW/COMPLETION_REPORT.md
    ./scripts/agent.sh publish-completion-report VALIDATEKNOW markdown
    ./scripts/agent.sh verify-completion-report VALIDATEKNOW

    # Baseline: validate already succeeds with zero knowledge-scope diffs
    # at all (unaffected by this fix — the common case).
    ./scripts/agent.sh validate VALIDATEKNOW

    # (1) A real application-scope violation still fails validate closed,
    # with zero knowledge-scope diffs in the picture at all.
    printf 'rogue application edit\n' > rogue.txt
    if ./scripts/agent.sh validate VALIDATEKNOW; then echo "FAIL: validate accepted an unmapped application-scope path" >&2; exit 1; fi
    rm -f rogue.txt

    # (2) A knowledge-scope (docs/wiki/**) diff with no recorded-complete
    # knowledge transaction still fails validate closed.
    printf '# Lesson\n' > docs/wiki/lesson.md
    if ./scripts/agent.sh validate VALIDATEKNOW; then echo "FAIL: validate accepted a knowledge-scope diff with no recorded transaction" >&2; exit 1; fi

    # (3) A mismatched not_applicable (real diff present) still fails
    # validate closed.
    ./scripts/agent.sh knowledge-done VALIDATEKNOW not_applicable
    if ./scripts/agent.sh validate VALIDATEKNOW; then echo "FAIL: validate accepted knowledge_state=not_applicable despite a real diff" >&2; exit 1; fi

    # (4) The corrected, legitimate case: the knowledge transaction actually
    # happened and is recorded KNOWLEDGE_DONE — validate now succeeds
    # instead of re-rejecting the same diff DONE (below) will independently
    # accept. Proven both before and after the DONE handoff transition.
    ./scripts/agent.sh knowledge-done VALIDATEKNOW KNOWLEDGE_DONE
    ./scripts/agent.sh validate VALIDATEKNOW
    ./scripts/agent.sh handoff VALIDATEKNOW DONE
    ./scripts/agent.sh validate VALIDATEKNOW

    # (5) Consistency still holds post-DONE: removing the only knowledge-
    # scope diff while knowledge_state stays KNOWLEDGE_DONE fails validate
    # closed (same zero-diff-but-claimed-complete rejection DONE and
    # delivery-check both use).
    rm -f docs/wiki/lesson.md
    if ./scripts/agent.sh validate VALIDATEKNOW; then echo "FAIL: validate accepted KNOWLEDGE_DONE with zero knowledge-scope diffs" >&2; exit 1; fi)
  echo 'agent validate knowledge-scope tests passed'
}

# Regression test for a `scripts/wiki-lint.sh` failure: its
# whole-vault scans (task-reference grep, duplicate-title find, wikilink
# grep, and the per-page orphan-check grep) each re-scanned the script's
# own previously-generated docs/wiki/lint-report.md, since only the
# page-content loop's own `$pages` list excluded it by name — every other
# scan walked `$wiki_root` directly. A prior run's own error-message text
# (which quotes an offending token verbatim, e.g. a broken `[[slug]]` or a
# bad `title:` line) could then itself look like real page content on the
# *next* run: a stale false-positive error that never existed in any real
# page, or a stale false-negative that hides a real orphan because the old
# report happened to mention that page's slug somewhere. Proves, from a
# clean, fully-valid vault (zero real broken links, zero real duplicate
# titles, zero real bad sources) with a lint-report.md deliberately
# pre-seeded to contain exactly those four kinds of stale, no-longer-real
# findings: the fixed script reports zero errors and correctly still flags
# the one real orphan page (not suppressed by the stale report's incidental
# mention of its slug), on a clean run and unchanged on a second consecutive
# run (idempotence — the report the first run just wrote must not itself
# start poisoning the second).
wiki_lint_self_scan_test() {
  tmp=$(mktemp -d /tmp/deterministic-wikilintself.XXXXXX); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/docs/wiki/decisions" "$tmp/scripts"
  cp "$root/scripts/wiki-lint.sh" "$tmp/scripts/"
  printf '%s\n' '---' 'title: real-page' 'status: current' 'source: AGENTS.md' '---' '' 'A clean page with no links.' \
    > "$tmp/docs/wiki/decisions/real-page.md"
  printf '%s\n' '---' 'title: orphan-candidate' 'status: current' 'source: AGENTS.md' '---' '' 'A genuinely unlinked page.' \
    > "$tmp/docs/wiki/decisions/orphan-candidate.md"
  printf '# AGENTS\n' > "$tmp/AGENTS.md"
  # Simulate a prior run's own stale report, quoting tokens that are not
  # (or no longer) real: an already-fixed broken link, an already-fixed
  # duplicate title, an already-fixed bad source, and an incidental
  # mention of the real orphan page's own slug.
  printf '%s\n' '# Wiki lint report' '' 'Generated by `scripts/wiki-lint.sh`.' '' '## Results' '' \
    '- ERROR broken wikilink: `[[stale-broken-link]]`' \
    '- ERROR duplicate title: `real-page`' \
    '- ERROR nonexistent provenance source: `docs/wiki/decisions/gone.md` → `gone.md`' \
    '- (superseded note, mentions [[orphan-candidate]] only in passing)' \
    '' 'Errors: 3' 'Warnings: 0' \
    > "$tmp/docs/wiki/lint-report.md"
  (cd "$tmp"
    if ! sh scripts/wiki-lint.sh > lint-output-1.txt 2>&1; then cat lint-output-1.txt >&2; echo "FAIL: wiki-lint reported an error on a fully clean vault (self-scan of stale lint-report.md)" >&2; exit 1; fi
    grep -q '^wiki lint: 0 error(s), 2 warning(s)$' lint-output-1.txt || { cat lint-output-1.txt >&2; echo "FAIL: expected exactly 0 errors and 2 real orphan warnings (real-page + orphan-candidate), got a different count" >&2; exit 1; }
    grep -Fq 'orphan-candidate.md' docs/wiki/lint-report.md || { cat docs/wiki/lint-report.md >&2; echo "FAIL: the genuinely unlinked orphan-candidate page was not flagged — its slug being incidentally mentioned in the stale prior report must not suppress a real orphan warning" >&2; exit 1; }
    grep -Fq 'stale-broken-link' docs/wiki/lint-report.md && { cat docs/wiki/lint-report.md >&2; echo "FAIL: the stale prior report's own broken-wikilink text was re-detected as if it were real page content" >&2; exit 1; }
    grep -Fq 'gone.md' docs/wiki/lint-report.md && { cat docs/wiki/lint-report.md >&2; echo "FAIL: the stale prior report's own bad-source text was re-detected as if it were real page content" >&2; exit 1; }

    # Idempotence: the report this run just wrote (which itself now
    # legitimately mentions "real-page.md" and "orphan-candidate.md" in its
    # own orphan warnings) must not poison a second consecutive run either.
    if ! sh scripts/wiki-lint.sh > lint-output-2.txt 2>&1; then cat lint-output-2.txt >&2; echo "FAIL: wiki-lint reported an error on the second consecutive run of an unchanged, fully clean vault" >&2; exit 1; fi
    grep -q '^wiki lint: 0 error(s), 2 warning(s)$' lint-output-2.txt || { cat lint-output-2.txt >&2; echo "FAIL: second run's own freshly-generated report must not introduce new false errors" >&2; exit 1; })
  echo 'wiki-lint self-scan regression test passed'
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
  cp "$root/scripts/agent.sh" "$root/scripts/worker-run.sh" "$root/scripts/exec-policy.sh" "$tmp/scripts/"; chmod +x "$tmp/scripts/worker-run.sh" "$tmp/scripts/exec-policy.sh"
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
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp/.agents/runs/STANDALONE/RUN.yaml"
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
    # RED/GREEN: IMPLEMENTED is still rejected with zero evidence recorded.
    if ./scripts/agent.sh handoff STANDALONE IMPLEMENTED; then
      echo "FAIL: standalone IMPLEMENTED succeeded with no RED/GREEN evidence at all" >&2; exit 1
    fi

    # (2) Valid RED, attributable to full_lifecycle (the default role — no
    # AGENT_ROLE override), is required and accepted.
    printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\nexpected_failure: TestImpl fails: registry returns zero tasks before the new lookup method exists\n' \
      | ./scripts/agent.sh worker-evidence STANDALONE RED fail
    if ./scripts/agent.sh handoff STANDALONE IMPLEMENTED; then
      echo "FAIL: standalone IMPLEMENTED succeeded with RED but no GREEN evidence" >&2; exit 1
    fi

    # (3) Valid GREEN, same role, completes the pair; config.txt's exemption
    # covers the other scope path exactly as under orchestrated topology.
    printf 'command: go test ./... -run TestImpl\ntarget: impl.txt\n' \
      | ./scripts/agent.sh worker-evidence STANDALONE GREEN pass
    grep -Fq 'role: "full_lifecycle"' .agents/runs/STANDALONE/worker-evidence/RED-1.yaml
    grep -Fq 'role: "full_lifecycle"' .agents/runs/STANDALONE/worker-evidence/GREEN-1.yaml
    ./scripts/agent.sh handoff STANDALONE IMPLEMENTED
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
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    > "$tmp2/.agents/runs/STANDALONE2/RUN.yaml"
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
    ./scripts/agent.sh handoff STANDALONE2 IMPLEMENTED)
  rm -rf "$tmp2"
  echo 'agent standalone tests passed'
}

# Deterministic per-task branch isolation. A run whose RUN.yaml has no repository.task_branch
# key (like FIX/ROLE above) is untouched by any of this —
# proven by reusing those exact fixtures unmodified. BRANCH below is template-style: it must
# establish a task/<TASK-ID>-<slug> branch from the canonical branch's exact tip before
# baseline is even possible, and every mutating phase after that must run on that exact branch.
branch_test() {
  tmp=$(mktemp -d /tmp/deterministic-branch.XXXXXX); tmp2=$(mktemp -d /tmp/deterministic-branch-dirty.XXXXXX); trap 'rm -rf "$tmp" "$tmp2"' EXIT
  mkdir -p "$tmp/.agents/runs/BRANCH/review" "$tmp/.agents/modes" "$tmp/scripts" "$tmp/tasks"
  cp "$root/scripts/agent.sh" "$tmp/scripts/"; cp "$root/.agents/config.yaml" "$tmp/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp/.agents/modes/"
  printf 'BRANCH\n' > "$tmp/.agents/ACTIVE_RUN"; printf '# Task\n' > "$tmp/.agents/runs/BRANCH/TASK.md"; printf '# Evidence\n' > "$tmp/.agents/runs/BRANCH/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: authorized.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp/.agents/runs/BRANCH/PLAN.md"
  printf '%s\n' 'task:' '  id: BRANCH' 'repository:' '  base_sha: PENDING' '  canonical_branch: PENDING' '  task_branch: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/BRANCH-sample-feature.md' '  revision: PENDING' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp/.agents/runs/BRANCH/RUN.yaml"
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
    if ./scripts/agent.sh handoff BRANCH IMPLEMENTED; then exit 1; fi
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope BRANCH; then exit 1; fi
    git checkout -q --detach "$canonical_sha"
    if ./scripts/agent.sh handoff BRANCH IMPLEMENTED; then exit 1; fi
    git checkout -q -b random-feature
    if ./scripts/agent.sh handoff BRANCH IMPLEMENTED; then exit 1; fi
    if AGENT_ROLE=implementation_worker ./scripts/agent.sh verify-scope BRANCH; then exit 1; fi
    git checkout -q main; git branch task/OTHER-unrelated "$canonical_sha"; git checkout -q task/OTHER-unrelated
    if ./scripts/agent.sh handoff BRANCH IMPLEMENTED; then exit 1; fi
    git checkout -q main; git branch -D task/OTHER-unrelated random-feature > /dev/null
    git checkout -q task/BRANCH-sample-feature
    cp .agents/runs/BRANCH/RUN.yaml tampered.original
    sed 's#task_branch: "task/BRANCH-sample-feature"#task_branch: "task/BRANCH-tampered"#' tampered.original > .agents/runs/BRANCH/RUN.yaml
    if ./scripts/agent.sh handoff BRANCH IMPLEMENTED; then exit 1; fi
    mv tampered.original .agents/runs/BRANCH/RUN.yaml
    ./scripts/agent.sh handoff BRANCH IMPLEMENTED; ./scripts/agent.sh handoff BRANCH CODE_DONE; ./scripts/agent.sh delivery-check BRANCH
    git checkout -q main; if ./scripts/agent.sh branch BRANCH; then exit 1; fi; git checkout -q task/BRANCH-sample-feature)
  mkdir -p "$tmp2/.agents/runs/CONFLICT/review" "$tmp2/scripts" "$tmp2/.agents/modes"
  cp "$root/scripts/agent.sh" "$tmp2/scripts/"; cp "$root/.agents/config.yaml" "$tmp2/.agents/"; cp "$root/.agents/modes/"*.yaml "$tmp2/.agents/modes/"
  printf '# Task\n' > "$tmp2/.agents/runs/CONFLICT/TASK.md"; printf '# Evidence\n' > "$tmp2/.agents/runs/CONFLICT/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: tracked.txt' '    criteria: [AC-1]' '---' '# Plan' > "$tmp2/.agents/runs/CONFLICT/PLAN.md"
  printf '%s\n' 'task:' '  id: CONFLICT' 'repository:' '  base_sha: PENDING' '  canonical_branch: PENDING' '  task_branch: PENDING' 'task_source:' '  type: none' '  revision: not_applicable' 'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' 'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' 'baseline:' '  status: pending' 'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' > "$tmp2/.agents/runs/CONFLICT/RUN.yaml"
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
command=${1:-}
# The independent roles (Reviewer, QA, Verifier) are read-only observers that
# may only record their own gate: they can never move the lifecycle, freeze, or
# touch implementation evidence. Explorer and Architect are planning-phase
# specialists that return findings to the orchestrator: they may read and
# validate, and record nothing at all.
# `summary` and `report` read run state only. `report` writes one disposable file outside the repository.
case "$execution_role" in
  independent_reviewer|independent_qa|independent_verifier)
    case "$command" in role|status|effective|pipeline|verify-*|freshness|validate|patch-fingerprint|gate|summary|report) ;; *) fail "command denied for $execution_role" ;; esac ;;
  explorer|architect)
    case "$command" in role|status|effective|pipeline|verify-*|freshness|validate|patch-fingerprint|summary|report) ;; *) fail "command denied for $execution_role" ;; esac ;;
esac
case "$command" in
  role) printf 'role=%s\n' "$execution_role" ;;
  status) id=$(active_run); echo "active_task=${id:-none}"; echo "implementation_allowed=$( [ -n "$id" ] && echo true || echo false )"; effective "$id" ;;
  effective) effective "${2:-}" ;;
  baseline) require_full_lifecycle; baseline "${2:?usage: $0 baseline <TASK-ID>}" ;;
  branch) require_full_lifecycle; branch_setup "${2:?usage: $0 branch <TASK-ID>}" ;;
  classify) require_full_lifecycle; classify "${2:?usage: $0 classify <TASK-ID> <TRIVIAL|STANDARD|COMPLEX|CRITICAL> [review]}" "${3:?usage: $0 classify <TASK-ID> <TRIVIAL|STANDARD|COMPLEX|CRITICAL> [review]}" "${4:-}" ;;
  pipeline) pipeline_show "${2:?usage: $0 pipeline <TASK-ID>}" ;;
  summary) summary_run "${2:-}" ;;
  report) report_run "${2:-}" ;;
  decide) require_full_lifecycle; id=${2:?usage: $0 decide <TASK-ID> <RED|GREEN|REFACTOR|FIX> [--failure CODE] [--model M] [--effort E] [--delegation N] [--context-bytes B]}; ph=${3:?usage: $0 decide <TASK-ID> <PHASE> ...}; shift 3; decide "$id" "$ph" "$@" ;;
  decision-outcome) require_full_lifecycle; id=${2:?usage: $0 decision-outcome <TASK-ID> <PHASE> <success|failure> [k=v ...]}; ph=${3:?}; oc=${4:?}; shift 4; decision_outcome "$id" "$ph" "$oc" "$@" ;;
  freeze) require_full_lifecycle; freeze "${2:?usage: $0 freeze <TASK-ID>}" ;;
  refreeze) require_full_lifecycle; freeze "${2:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" refreeze "${3:?usage: $0 refreeze <TASK-ID> <AMENDMENT>}" ;;
  verify-freeze) verify_freeze "${2:?usage: $0 verify-freeze <TASK-ID>}" ;;
  verify-scope) verify_scope "${2:?usage: $0 verify-scope <TASK-ID>}" ;;
  verify-knowledge-scope) verify_knowledge_scope "${2:?usage: $0 verify-knowledge-scope <TASK-ID>}" ;;
  freshness) verify_freshness "${2:?usage: $0 freshness <TASK-ID>}" ;;
  handoff) [ "$execution_role" = full_lifecycle ] || [ "${3:-}" = IMPLEMENTING ] || fail "handoff phase denied for implementation_worker"; record_handoff "${2:?usage: $0 handoff <TASK-ID> <PHASE>}" "${3:?usage: $0 handoff <TASK-ID> <PHASE>}" ;;
  verify-handoff) verify_handoff "${2:?usage: $0 verify-handoff <TASK-ID>}" ;;
  delivery-check) require_full_lifecycle; delivery_check "${2:?usage: $0 delivery-check <TASK-ID>}" ;;
  worker-evidence) record_worker_evidence "${2:?usage: $0 worker-evidence <TASK-ID> <RED|GREEN|REFACTOR|FIX> <pass|fail>}" "${3:?usage: $0 worker-evidence <TASK-ID> <PHASE> <RESULT>}" "${4:?usage: $0 worker-evidence <TASK-ID> <PHASE> <RESULT>}" ;;
  verify-worker-evidence) verify_worker_evidence "${2:?usage: $0 verify-worker-evidence <TASK-ID>}" ;;
  gate) record_gate "${2:?usage: $0 gate <TASK-ID> <REVIEW|QA|VERIFY> <pass|fail>}" "${3:?usage: $0 gate <TASK-ID> <REVIEW|QA|VERIFY> <pass|fail>}" "${4:?usage: $0 gate <TASK-ID> <REVIEW|QA|VERIFY> <pass|fail>}" ;;
  terminate) require_full_lifecycle; terminate_run "${2:?usage: $0 terminate <TASK-ID> <FAILED|BLOCKED>}" "${3:?usage: $0 terminate <TASK-ID> <FAILED|BLOCKED>}" ;;
  cleanup) require_full_lifecycle; cleanup_run "${2:?usage: $0 cleanup <TASK-ID>}" ;;
  amend) require_full_lifecycle; amend_run "${2:?usage: $0 amend <TASK-ID>}" ;;
  patch-fingerprint) require_run "${2:?usage: $0 patch-fingerprint <TASK-ID>}"; task_patch_fingerprint "$2" ;;
  window-open) require_full_lifecycle; window_open "${2:?usage: $0 window-open <TASK-ID>}" ;;
  window-close) require_full_lifecycle; window_close "${2:?usage: $0 window-close <TASK-ID> <BEFORE> [EXIT-STATUS]}" "${3:-}" "${4:-0}" ;;
  verify-gates) verify_lifecycle_gates "${2:?usage: $0 verify-gates <TASK-ID>}"; echo "lifecycle gates verified: $2" ;;
  verify-seal) verify_seal "${2:?usage: $0 verify-seal <TASK-ID>}"; echo "lifecycle seal verified: $2" ;;
  task-source-status) task_source_status "${2:?usage: $0 task-source-status <TASK-ID>}" ;;
  task-source-relocate) task_source_relocate "${2:?usage: $0 task-source-relocate <TASK-ID> <NEW-PATH>}" "${3:?usage: $0 task-source-relocate <TASK-ID> <NEW-PATH>}" ;;
  knowledge-done) knowledge_done "${2:?usage: $0 knowledge-done <TASK-ID> [not_applicable]}" "${3:-KNOWLEDGE_DONE}" ;;
  publish-completion-report) publish_completion_report "${2:?usage: $0 publish-completion-report <TASK-ID> [ADAPTER]}" "${3:-markdown}" ;;
  verify-completion-report) verify_completion_report "${2:?usage: $0 verify-completion-report <TASK-ID>}" ;;
  validate) validate_run "${2:?usage: $0 validate <TASK-ID>}" ;;
  test) require_full_lifecycle; fixture_test; sh "$root/scripts/exec-policy-test.sh"; sh "$root/scripts/lifecycle-test.sh"; sh "$root/scripts/oversight-test.sh"; branch_test; policy_test; standalone_test; worker_evidence_write_failure_test; knowledge_scope_test; delivery_check_knowledge_scope_test; validate_knowledge_scope_test; wiki_lint_self_scan_test ;;
  role-test) require_full_lifecycle; role_test ;;
  *) echo "usage: $0 {role|status|effective|baseline|branch|classify|pipeline|freeze|refreeze|verify-freeze|verify-scope|verify-knowledge-scope|freshness|handoff|verify-handoff|delivery-check|worker-evidence|verify-worker-evidence|gate|amend|terminate|cleanup|patch-fingerprint|window-open|window-close|verify-gates|verify-seal|task-source-relocate|task-source-status|knowledge-done|publish-completion-report|verify-completion-report|validate|summary|report|test|role-test} [TASK-ID]" >&2; exit 2 ;;
esac

#!/bin/sh
# The single execution-policy resolver. Pure function of its inputs: no clock,
# no randomness, no model call, no run state. `agent.sh decide` gathers the
# inputs from a run and persists the result; nothing else may choose these values.
#
#   exec-policy.sh resolve --class C --topology T --review yes|no --attempt N
#       --retry-limit N [--failure CODE --prev "M E C EVENTS"]
#       [--model M] [--effort E] [--delegation N] [--context-bytes B] < scope-paths
#   exec-policy.sh explain < decision      reason codes -> text (no LLM)
#   exec-policy.sh check-capabilities      compare the ladder with the local Codex model cache
#   exec-policy.sh test
#
# Precedence (one order, top wins):
#   1 hard limits (config `hard:`, pipeline bounds, retry limit)  never weakened
#   2 explicit operator override (--model/--effort/--delegation/--context-bytes)
#   3 deterministic task policy (class + PLAN.md scope evidence [+ escalation steps])
#   4 provider capability validation / normalization
#   5 one resolved decision (key=value lines on stdout)
# Exit: 0 resolved | 2 usage or invalid config | 3 override rejected | 4 hard failure.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
config=${EXEC_POLICY_CONFIG:-$root/.agents/config.yaml}
# Capability input: models the local install cannot serve (space separated).
unavailable=${EXEC_POLICY_UNAVAILABLE_MODELS:-}

die() { echo "exec-policy: $*" >&2; exit 2; }
reject() { echo "exec-policy: REJECTED $1: $2" >&2; exit 3; }
hard() { echo "exec-policy: HARD_FAILURE $1: $2" >&2; exit 4; }

# --- config access: nested `key: value` YAML, 2-space indent, no lists/comments-on-values ---
cfg_walk() { # MODE(val|keys) path... ; prints the scalar, or the child keys in order
  mode=$1; shift
  awk -v mode="$mode" -v want="$*" '
    /^[[:space:]]*(#|$)/ { next }
    { ind=match($0, /[^ ]/) - 1; d=int(ind / 2); line=substr($0, ind + 1)
      key=line; sub(/:.*/, "", key); val=line; sub(/^[^:]*:[[:space:]]*/, "", val); gsub(/"/, "", val)
      for (i = d + 1; i < 32; i++) delete st[i]
      st[d]=key; p=st[0]; for (i = 1; i <= d; i++) p = p " " st[i]
      if (mode == "val" && p == want) { print val; exit }
      if (mode == "keys") { par=p; sub(/ [^ ]*$/, "", par); if (d > 0 && par == want) print key }
    }' "$config"
}
cfg() { cfg_walk val execution_policy "$@"; }
cfg_keys() { cfg_walk keys execution_policy "$@"; }
kv() { for kv_t in $1; do case "$kv_t" in "$2="*) printf '%s\n' "${kv_t#*=}"; return 0 ;; esac; done; return 1; }
pipe() { # CLASS KEY (pipelines block of the same config; the canonical task classification)
  awk -v c="$1" -v k="$2" '
    /^pipelines:$/ { i=1; next } i && /^[^[:space:]]/ { exit }
    i && /^  [A-Z]+:$/ { cur=$1; sub(/:$/, "", cur); next }
    i && cur == c && $0 ~ "^    " k ":" { v=$0; sub(/^[^:]*:[[:space:]]*/, "", v); print v; exit }' "$config"
}
nth() { nth_n=$1; shift; [ "$nth_n" -ge 1 ] && [ "$nth_n" -le $# ] || return 1; eval "printf '%s\n' \"\${$nth_n}\""; }
idx() { idx_i=1; idx_w=$1; shift; for idx_t in "$@"; do [ "$idx_t" = "$idx_w" ] && { echo "$idx_i"; return 0; }; idx_i=$((idx_i + 1)); done; return 1; }
int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
join() { join_o=''; for join_t in $1; do join_o="${join_o:+$join_o,}$join_t"; done; printf '%s' "${join_o:-none}"; }

load_config() {
  [ -f "$config" ] || die "config not found: $config"
  revision=$(cfg revision); int "$revision" || die "execution_policy.revision missing or not an integer"
  max_esc=$(cfg hard max_escalations); max_deleg=$(cfg hard max_delegation); max_ctx=$(cfg hard max_context_bytes)
  int "$max_esc" && int "$max_deleg" && int "$max_ctx" || die "execution_policy.hard.* must be integers"
  forbidden=$(cfg hard forbidden_efforts | tr ',' ' ')
  efforts_order=$(cfg effort_order); [ -n "$efforts_order" ] || die "execution_policy.effort_order missing"
  for f in $forbidden; do idx "$f" $efforts_order >/dev/null && die "forbidden effort $f is in effort_order"; done
  sensitive=$(cfg evidence sensitive_paths); wide=$(cfg evidence wide_scope_paths); int "$wide" || die "evidence.wide_scope_paths must be an integer"
  models=$(cfg_keys providers codex models); [ -n "$models" ] || die "providers.codex.models missing"
  [ "$(cfg providers codex cache_control)" = none ] || die "providers.codex.cache_control: only 'none' is implemented (no explicit cache control is exposed by codex exec); refusing a fake TTL"
  n_models=$(echo $models | wc -w | tr -d ' ')
  for m in $models; do
    for e in $(model_efforts "$m"); do
      idx "$e" $efforts_order >/dev/null || die "model $m: effort $e is not in effort_order"
    done
  done
}
model_efforts() { kv "$(cfg providers codex models "$1")" efforts | tr ',' ' '; }

# --- resolution core (globals in, R_* globals out); never prints, may reject/hard-fail ---
compute_model_effort() {
  # model
  tier=$(kv "$class_line" tier); mreason=CLASS_TIER
  [ "$sens" -gt 0 ] && { tier=$((tier + 1)); mreason="$mreason,SENSITIVE_PATHS"; }
  [ "$e_model" -gt 0 ] && { tier=$((tier + e_model)); mreason="$mreason,ESCALATED_CAPABILITY"; }
  [ "$tier" -le "$n_models" ] || tier=$n_models
  norm=''
  if [ -n "$o_model" ]; then
    idx "$o_model" $models >/dev/null || reject UNKNOWN_MODEL "$o_model is not in the provider ladder ($(join "$models"))"
    idx "$o_model" $unavailable >/dev/null && reject MODEL_UNAVAILABLE "$o_model is unavailable"
    R_MODEL=$o_model; mreason=OPERATOR_OVERRIDE
  else
    while :; do
      cand=$(nth "$tier" $models) || hard NO_AVAILABLE_MODEL "no available model at or above tier $tier"
      idx "$cand" $unavailable >/dev/null || break
      tier=$((tier + 1)); mreason="$mreason,MODEL_UNAVAILABLE_UPGRADED"
      [ "$tier" -le "$n_models" ] || hard NO_AVAILABLE_MODEL "no available model at or above the required tier"
    done
    R_MODEL=$cand
  fi
  R_MODEL_REASON=$mreason
  # effort
  supported=$(model_efforts "$R_MODEL")
  if [ -n "$o_effort" ]; then
    idx "$o_effort" $forbidden >/dev/null && reject HARD_FORBIDDEN_EFFORT "$o_effort is forbidden by execution_policy.hard.forbidden_efforts"
    idx "$o_effort" $efforts_order >/dev/null || reject UNKNOWN_EFFORT "$o_effort (want: $(join "$efforts_order"))"
    idx "$o_effort" $supported >/dev/null || reject UNSUPPORTED_EFFORT "$R_MODEL supports only: $(join "$supported")"
    R_EFFORT=$o_effort; ereason=OPERATOR_OVERRIDE
  else
    want=$(idx "$(kv "$class_line" effort)" $efforts_order) || die "class effort not in effort_order"; ereason=CLASS_BASE
    [ "$wide_hit" = yes ] && { want=$((want + 1)); ereason="$ereason,WIDE_SCOPE"; }
    [ "$e_effort" -gt 0 ] && { want=$((want + e_effort)); ereason="$ereason,ESCALATED_REASONING"; }
    n_eff=$(echo $efforts_order | wc -w | tr -d ' ')
    [ "$want" -le "$n_eff" ] || { want=$n_eff; norm="$norm,CLAMPED_TO_SCALE_MAX"; }
    R_EFFORT=''; i=$want
    while [ "$i" -le "$n_eff" ]; do
      c=$(nth "$i" $efforts_order); if idx "$c" $supported >/dev/null; then R_EFFORT=$c; break; fi; i=$((i + 1))
    done
    if [ -z "$R_EFFORT" ]; then
      i=$want; while [ "$i" -ge 1 ]; do c=$(nth "$i" $efforts_order); if idx "$c" $supported >/dev/null; then R_EFFORT=$c; break; fi; i=$((i - 1)); done
      [ -n "$R_EFFORT" ] || hard NO_SUPPORTED_EFFORT "$R_MODEL supports no effort on the configured scale"
      norm="$norm,CLAMPED_TO_MODEL_MAX_EFFORT"
    elif [ "$R_EFFORT" != "$(nth "$want" $efforts_order)" ]; then norm="$norm,EFFORT_RAISED_TO_SUPPORTED"; fi
  fi
  R_EFFORT_REASON=$ereason
  R_NORM=${norm#,}
}
compute_ctx() {
  # context (bytes of dynamic context; the stable prefix is outside this budget)
  ctx=$(kv "$class_line" context_bytes); creason=CLASS_BUDGET
  [ "$wide_hit" = yes ] && { ctx=$((ctx + ctx / 2)); creason="$creason,WIDE_SCOPE"; }
  n=0; while [ "$n" -lt "$e_ctx" ]; do ctx=$((ctx * 2)); n=$((n + 1)); done; [ "$e_ctx" -gt 0 ] && creason="$creason,ESCALATED_CONTEXT"
  if [ -n "$o_ctx" ]; then ctx=$o_ctx; creason=OPERATOR_OVERRIDE; fi
  if [ "$ctx" -gt "$max_ctx" ]; then ctx=$max_ctx; creason="$creason,CAPPED_AT_HARD_LIMIT"; fi
  R_CTX=$ctx; R_CTX_REASON=$creason
}
compute() {
  if [ "$provider" = codex ]; then compute_model_effort
  else R_MODEL=session R_MODEL_REASON=STANDALONE_SESSION_OWNED R_EFFORT=session R_EFFORT_REASON=STANDALONE_SESSION_OWNED R_NORM=''; fi
  compute_ctx
}


resolve() {
  class='' topology='' review='' attempt='' retry_limit='' failure='' prev='0 0 0 0'
  o_model='' o_effort='' o_deleg='' o_ctx=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) class=${2:?}; shift 2 ;; --topology) topology=${2:?}; shift 2 ;; --review) review=${2:?}; shift 2 ;;
      --attempt) attempt=${2:?}; shift 2 ;; --retry-limit) retry_limit=${2:?}; shift 2 ;;
      --failure) failure=${2:?}; shift 2 ;; --prev) prev=${2:?}; shift 2 ;;
      --model) o_model=${2:?}; shift 2 ;; --effort) o_effort=${2:?}; shift 2 ;;
      --delegation) o_deleg=${2:?}; shift 2 ;; --context-bytes) o_ctx=${2:?}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  load_config
  class_line=$(cfg classes "$class") || true; [ -n "$class_line" ] || die "no execution_policy.classes entry for '$class'"
  case "$topology" in standalone|orchestrated) ;; *) die "invalid topology: $topology" ;; esac
  case "$review" in yes|no) ;; *) die "--review must be yes|no" ;; esac
  int "$attempt" && int "$retry_limit" || die "--attempt and --retry-limit must be integers"
  [ -z "$o_deleg" ] || int "$o_deleg" || reject INVALID_OVERRIDE "delegation must be an integer"
  [ -z "$o_ctx" ] || { int "$o_ctx" && [ "$o_ctx" -gt 0 ]; } || reject INVALID_OVERRIDE "context-bytes must be a positive integer"
  set -- $prev; [ $# -eq 4 ] || die "--prev wants 'ESC_MODEL ESC_EFFORT ESC_CONTEXT EVENTS'"
  e_model=$1 e_effort=$2 e_ctx=$3 events=$4
  [ "$attempt" -le $((retry_limit + 1)) ] || hard RETRY_LIMIT_EXHAUSTED "attempt $attempt exceeds 1 + the bounded fix limit ($retry_limit)"

  # deterministic scope evidence from stdin (one repository path per line)
  n_paths=0 sens=0 areas=''
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n_paths=$((n_paths + 1)); top=${p%%/*}; case " $areas " in *" $top "*) ;; *) areas="$areas $top" ;; esac
    for s in $sensitive; do case "$p" in "$s"*) sens=$((sens + 1)); break ;; esac; done
  done
  n_areas=$(echo $areas | wc -w | tr -d ' ')
  wide_hit=no; [ "$n_paths" -gt "$wide" ] && wide_hit=yes

  provider=session
  [ "$topology" = orchestrated ] && provider=codex
  if [ "$provider" = session ]; then
    [ -z "$o_model$o_effort" ] || reject OVERRIDE_NOT_APPLICABLE "model/effort overrides cannot steer a standalone full_lifecycle session; the operator owns its model and effort"
    # nothing to escalate on model/effort: those belong to the session
  fi

  escalation=none; esc_from=''
  compute

  # bounded escalation: a NEW decision, produced by changing exactly one counter
  if [ -n "$failure" ]; then
    case "$failure" in
      TRANSIENT) order=''; escalation=RETRY_SAME_CAPABILITY ;;
      INSUFFICIENT_REASONING) order='effort model' ;;
      INSUFFICIENT_CAPABILITY) order='model effort' ;;
      CONTEXT_MISSING) order='context' ;;
      SCOPE_VIOLATION|POLICY_VIOLATION) hard NON_RETRYABLE_FAILURE "$failure needs an orchestrator decision (amendment), not a retry" ;;
      *) die "unknown failure category: $failure (want TRANSIENT|INSUFFICIENT_REASONING|INSUFFICIENT_CAPABILITY|CONTEXT_MISSING|SCOPE_VIOLATION|POLICY_VIOLATION)" ;;
    esac
    if [ -n "$order" ]; then
      [ "$events" -lt "$max_esc" ] || hard ESCALATION_LIMIT_EXHAUSTED "$events escalations already used (max $max_esc)"
      b_model=$R_MODEL b_effort=$R_EFFORT b_ctx=$R_CTX; done_esc=no
      for dim in $order; do
        s_m=$e_model s_e=$e_effort s_c=$e_ctx
        case "$dim" in model) e_model=$((e_model + 1)) ;; effort) e_effort=$((e_effort + 1)) ;; context) e_ctx=$((e_ctx + 1)) ;; esac
        compute
        case "$dim" in
          model) [ "$R_MODEL" != "$b_model" ] && done_esc=yes ;;
          effort) [ "$R_EFFORT" != "$b_effort" ] && done_esc=yes ;;
          context) [ "$R_CTX" != "$b_ctx" ] && done_esc=yes ;;
        esac
        if [ "$done_esc" = yes ]; then
          case "$dim" in model) escalation=ESCALATED_CAPABILITY ;; effort) escalation=ESCALATED_REASONING ;; context) escalation=ESCALATED_CONTEXT ;; esac
          esc_from="model=$b_model effort=$b_effort context_bytes=$b_ctx"; events=$((events + 1)); break
        fi
        e_model=$s_m e_effort=$s_e e_ctx=$s_c
      done
      [ "$done_esc" = yes ] || hard NO_ESCALATION_PATH "$failure cannot be escalated further (dimension at its ceiling or pinned by an operator override)"
    fi
  fi

  # delegation and the remaining derived dimensions (never escalated)
  pipe_max=$(pipe "$class" max_explorers); int "$pipe_max" || pipe_max=0
  ceiling=$pipe_max; [ "$max_deleg" -ge "$ceiling" ] || ceiling=$max_deleg
  if [ "$ceiling" -eq 0 ]; then deleg=0; dreason=CLASS_FORBIDS_EXPLORERS
  elif [ "$n_areas" -ge 2 ]; then deleg=$n_areas; dreason=INDEPENDENT_AREAS; [ "$deleg" -le "$ceiling" ] || { deleg=$ceiling; dreason="$dreason,CAPPED_AT_CLASS_BOUND"; }
  else deleg=1; dreason=SINGLE_AREA; fi
  if [ -n "$o_deleg" ]; then
    if [ "$o_deleg" -gt "$ceiling" ]; then deleg=$ceiling; dreason="OPERATOR_OVERRIDE,CLAMPED_TO_HARD_LIMIT"; else deleg=$o_deleg; dreason=OPERATOR_OVERRIDE; fi
  fi
  ev=$(pipe "$class" evidence); ar=$(pipe "$class" architect); qa=$(pipe "$class" qa)
  if [ "$ev" != yes ]; then planning=minimal; preason=PIPELINE_NO_EVIDENCE
  elif [ "$ar" != yes ]; then planning=lightweight; preason=PIPELINE_EVIDENCE_NO_ARCHITECT
  else planning=architected; preason=PIPELINE_ARCHITECT; fi
  validation=verify; [ "$qa" = yes ] && validation=qa+verify; [ "$review" = yes ] && validation=review+$validation
  esc_limit=$max_esc

  if [ "$provider" = codex ]; then cache=stable_prefix cache_reason=NO_EXPLICIT_CACHE_CONTROL
  else cache=none cache_reason=SESSION_OWNED; fi
  applied=''; [ -n "$o_model" ] && applied="$applied model"; [ -n "$o_effort" ] && applied="$applied effort"
  [ -n "$o_deleg" ] && applied="$applied delegation"; [ -n "$o_ctx" ] && applied="$applied context_bytes"
  cat <<EOF
policy_version=$revision
class=$class
topology=$topology
provider=$provider
attempt=$attempt
model=$R_MODEL
model_reason=$R_MODEL_REASON
effort=$R_EFFORT
effort_reason=$R_EFFORT_REASON
context_bytes=$R_CTX
context_reason=$R_CTX_REASON
cache_strategy=$cache
cache_ttl=none
cache_reason=$cache_reason
planning=$planning
planning_reason=$preason
delegation_limit=$deleg
delegation_reason=$dreason
validation=$validation
validation_reason=PIPELINE_GATES
retry_limit=$retry_limit
escalation_limit=$esc_limit
overrides=$(join "$applied")
normalization=${R_NORM:-none}
escalation=$escalation
escalation_from=${esc_from:-none}
esc_model=$e_model
esc_effort=$e_effort
esc_context=$e_ctx
esc_events=$events
EOF
}

explain() {
  while IFS='=' read -r k v; do
    case "$k" in
      *_reason|normalization|escalation)
        for c in $(printf '%s' "$v" | tr ',' ' '); do
          case "$c" in
            CLASS_TIER) t="the task class needs at least this model tier" ;; SENSITIVE_PATHS) t="scope touches sensitive paths: one tier higher" ;;
            WIDE_SCOPE) t="scope spans many paths: one step higher" ;; CLASS_BASE) t="base effort of the task class" ;;
            CLASS_BUDGET) t="base context budget of the task class" ;; OPERATOR_OVERRIDE) t="explicit operator override" ;;
            ESCALATED_CAPABILITY) t="escalated to a stronger model after a capability failure" ;; ESCALATED_REASONING) t="escalated to higher effort after a reasoning failure" ;;
            ESCALATED_CONTEXT) t="context budget doubled after a missing-context failure" ;; RETRY_SAME_CAPABILITY) t="transient failure: retried with unchanged capability" ;;
            MODEL_UNAVAILABLE_UPGRADED) t="required model unavailable: next stronger available model used" ;; STANDALONE_SESSION_OWNED) t="standalone: the session owner controls model and effort" ;;
            CLAMPED_TO_MODEL_MAX_EFFORT) t="desired effort above what the model supports: its maximum used" ;; CLAMPED_TO_SCALE_MAX) t="desired effort above the configured scale: scale maximum used" ;;
            EFFORT_RAISED_TO_SUPPORTED) t="desired effort unsupported by the model: next supported effort used" ;; CAPPED_AT_HARD_LIMIT|CLAMPED_TO_HARD_LIMIT) t="bounded by a hard safety limit" ;;
            CAPPED_AT_CLASS_BOUND) t="bounded by the class explorer bound" ;; CLASS_FORBIDS_EXPLORERS) t="this class allows no explorers" ;;
            INDEPENDENT_AREAS) t="scope spans independent top-level areas" ;; SINGLE_AREA) t="single-area scope: one explorer at most" ;;
            PIPELINE_NO_EVIDENCE) t="pipeline requires no evidence: minimal planning" ;; PIPELINE_EVIDENCE_NO_ARCHITECT) t="pipeline requires evidence but no architecture: lightweight planning" ;;
            PIPELINE_ARCHITECT) t="pipeline requires an architecture section: explicit planning" ;; PIPELINE_GATES) t="gates the class pipeline requires" ;;
            NO_EXPLICIT_CACHE_CONTROL) t="codex exec exposes no cache control: structural stable prefix only, no TTL" ;; SESSION_OWNED) t="no worker prompt is built" ;;
            none) continue ;; *) t="(no text for $c)" ;;
          esac
          printf '%s: %s — %s\n' "$k" "$c" "$t"
        done ;;
    esac
  done
}

check_capabilities() {
  load_config; cache=${CODEX_MODELS_CACHE:-$HOME/.codex/models_cache.json}
  [ -f "$cache" ] || { echo "no local Codex model cache at $cache; nothing to verify against"; return 0; }
  command -v jq >/dev/null 2>&1 || die "jq is required for check-capabilities"
  bad=0
  for m in $models; do
    have=$(jq -r --arg m "$m" '.models[] | select(.slug == $m) | [.supported_reasoning_levels[].effort] | join(",")' "$cache")
    if [ -z "$have" ]; then echo "MISSING model in local Codex cache: $m"; bad=1; continue; fi
    for e in $(model_efforts "$m"); do case ",$have," in *",$e,"*) ;; *) echo "UNSUPPORTED effort $e for $m (cache: $have)"; bad=1 ;; esac; done
  done
  [ "$bad" -eq 0 ] && echo "capabilities consistent with $cache"
  return "$bad"
}

case "${1:-}" in
  resolve) shift; resolve "$@" ;;
  explain) explain ;;
  check-capabilities) check_capabilities ;;
  *) die "usage: $0 resolve|explain|check-capabilities (tests: scripts/exec-policy-test.sh)" ;;
esac

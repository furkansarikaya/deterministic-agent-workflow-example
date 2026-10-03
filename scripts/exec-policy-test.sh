#!/bin/sh
# Mechanical tests for the execution-policy resolver (scripts/exec-policy.sh): no
# model call, no network, no run state. The run-level wiring (agent.sh decide,
# worker-run.sh consuming the decision) is exercised in scripts/lifecycle-test.sh.
# Run via `scripts/agent.sh test`, or directly.
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
ep="$root/scripts/exec-policy.sh"
tmp=$(mktemp -d /tmp/exec-policy-test.XXXXXX); trap 'rm -rf "$tmp"' EXIT
n=0
ok() { n=$((n + 1)); }
bad() { echo "FAIL: $*" >&2; exit 1; }

# res <paths-file|-> args... : resolver stdout in $out, exit code in $rc (stderr in $err)
res() {
  pf=$1; shift; [ "$pf" = - ] && pf=/dev/null
  rc=0; out=$(sh "$ep" resolve --topology "${TOPO:-orchestrated}" --review "${REVIEW:-no}" --retry-limit "${RETRY:-2}" "$@" < "$pf" 2> "$tmp/err") || rc=$?
  err=$(cat "$tmp/err")
}
f() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
is() { [ "$(f "$1")" = "$2" ] || bad "$CASE: $1 expected '$2', got '$(f "$1")' (exit $rc: $err)"; ok; }
has() { case ",$(f "$1")," in *",$2,"*) ok ;; *) bad "$CASE: $1 lacks $2 (got '$(f "$1")')" ;; esac; }
code() { [ "$rc" -eq "$1" ] || bad "$CASE: exit $rc, want $1 ($err)"; ok; }
errs() { case "$err" in *"$1"*) ok ;; *) bad "$CASE: stderr lacks '$1' (got: $err)" ;; esac; }

# Run a function with one variable set for that call only (dash would otherwise keep it).
with() { w_kv=$1; shift; w_k=${w_kv%%=*}; export "$w_kv"; w_rc=0; "$@" || w_rc=$?; unset "$w_k"; return "$w_rc"; }

# fixture config variants (the resolver reads EXEC_POLICY_CONFIG)
mkcfg() { sed "$2" "$root/.agents/config.yaml" > "$tmp/$1.yaml"; }
paths() { : > "$tmp/paths"; for p in "$@"; do echo "$p" >> "$tmp/paths"; done; echo "$tmp/paths"; }

CASE="case 1: TRIVIAL, no override -> minimum sufficient"
res "$(paths src/a.go)" --class TRIVIAL --attempt 1; code 0
is model gpt-5.6-luna; is effort low; is context_bytes 16384; is planning minimal; is delegation_limit 0
is validation verify; is overrides none; is normalization none; is escalation none
has model_reason CLASS_TIER; has effort_reason CLASS_BASE; has delegation_reason CLASS_FORBIDS_EXPLORERS

CASE="case 2: each class gets a stronger justified decision"
res - --class STANDARD --attempt 1; is model gpt-5.6-terra; is effort medium; is planning lightweight; is validation qa+verify
res - --class COMPLEX --attempt 1; is model gpt-5.6-terra; is effort high; is planning architected
with REVIEW=yes res - --class COMPLEX --attempt 1; is validation review+qa+verify
res - --class CRITICAL --attempt 1; is model gpt-5.6-sol; is effort xhigh; is context_bytes 163840

CASE="case 12: cost optimization never selects below the class tier (all classes, all ladders)"
for c in TRIVIAL STANDARD COMPLEX CRITICAL; do
  res - --class $c --attempt 1
  want=$(sed -n "s/^    $c: .*tier=\([0-9]*\).*/\1/p" "$root/.agents/config.yaml"); got=$(sed -n "s/^        $(f model): .*/x/p" "$root/.agents/config.yaml")
  pos=$(sed -n '/^      models:$/,/^  [a-z]/p' "$root/.agents/config.yaml" | grep -n "^        $(f model):" | cut -d: -f1)
  [ -n "$got" ] && [ "$pos" -ge "$want" ] || bad "$CASE: $c resolved below its required tier"; ok
done

CASE="evidence: sensitive scope raises the tier, wide scope raises effort and context"
res "$(paths .agents/x.yaml src/b.go)" --class TRIVIAL --attempt 1; is model gpt-5.6-terra; has model_reason SENSITIVE_PATHS
res "$(paths a/1 a/2 a/3 a/4 a/5 a/6 a/7 a/8 a/9)" --class TRIVIAL --attempt 1; is effort medium; is context_bytes 24576; has effort_reason WIDE_SCOPE
res "$(paths scripts/x)" --class CRITICAL --attempt 1; is model gpt-5.6-sol            # capped at the ladder top, not an error

CASE="case 3: valid operator override beats task policy"
res - --class TRIVIAL --attempt 1 --model gpt-5.6-sol --effort max; code 0; is model gpt-5.6-sol; is effort max
has model_reason OPERATOR_OVERRIDE; has effort_reason OPERATOR_OVERRIDE; is overrides model,effort

CASE="case 4/6: hard constraint beats an override; unsupported values are rejected, never reinterpreted"
res - --class TRIVIAL --attempt 1 --effort ultra; code 3; errs HARD_FORBIDDEN_EFFORT
res - --class TRIVIAL --attempt 1 --effort bogus; code 3; errs UNKNOWN_EFFORT
res - --class TRIVIAL --attempt 1 --model gpt-nope; code 3; errs UNKNOWN_MODEL
res - --class TRIVIAL --attempt 1 --delegation many; code 3; errs INVALID_OVERRIDE
res - --class COMPLEX --attempt 1 --delegation 3; code 0; is delegation_limit 2; has delegation_reason CLAMPED_TO_HARD_LIMIT
res - --class TRIVIAL --attempt 1 --delegation 2; is delegation_limit 0                 # a class that forbids explorers stays at 0
res - --class CRITICAL --attempt 1 --context-bytes 99999999; is context_bytes 262144; has context_reason CAPPED_AT_HARD_LIMIT
mkcfg fewefforts 's/^        gpt-5.6-terra: efforts=.*/        gpt-5.6-terra: efforts=low,medium,high/; s/^        gpt-5.6-sol: efforts=.*/        gpt-5.6-sol: efforts=low,medium,high/'
export EXEC_POLICY_CONFIG="$tmp/fewefforts.yaml"
res - --class STANDARD --attempt 1 --effort max; code 3; errs UNSUPPORTED_EFFORT
res - --class CRITICAL --attempt 1; code 0; is effort high; has normalization CLAMPED_TO_MODEL_MAX_EFFORT      # explicit, recorded clamp of a DERIVED value
unset EXEC_POLICY_CONFIG

CASE="case 5: unavailable capability is explicit"
with EXEC_POLICY_UNAVAILABLE_MODELS=gpt-5.6-terra res - --class STANDARD --attempt 1; is model gpt-5.6-sol; has model_reason MODEL_UNAVAILABLE_UPGRADED
with EXEC_POLICY_UNAVAILABLE_MODELS="gpt-5.6-terra gpt-5.6-sol" res - --class STANDARD --attempt 1; code 4; errs NO_AVAILABLE_MODEL
with EXEC_POLICY_UNAVAILABLE_MODELS=gpt-5.6-sol res - --class TRIVIAL --attempt 1 --model gpt-5.6-sol; code 3; errs MODEL_UNAVAILABLE

CASE="case 7: escalation yields a NEW explainable decision"
res - --class STANDARD --attempt 2 --failure INSUFFICIENT_REASONING --prev "0 0 0 0"; code 0
is model gpt-5.6-terra; is effort high; is escalation ESCALATED_REASONING; has effort_reason ESCALATED_REASONING
is escalation_from "model=gpt-5.6-terra effort=medium context_bytes=49152"; is esc_effort 1; is esc_events 1
res - --class STANDARD --attempt 3 --failure INSUFFICIENT_REASONING --prev "0 1 0 1"; is effort xhigh; is esc_events 2
res - --class STANDARD --attempt 4 --failure INSUFFICIENT_REASONING --prev "0 2 0 2"; code 4; errs RETRY_LIMIT_EXHAUSTED
with RETRY=9 res - --class STANDARD --attempt 4 --failure INSUFFICIENT_REASONING --prev "0 2 0 2"; code 4; errs ESCALATION_LIMIT_EXHAUSTED
res - --class STANDARD --attempt 2 --failure INSUFFICIENT_CAPABILITY --prev "0 0 0 0"; is model gpt-5.6-sol; is effort medium; is escalation ESCALATED_CAPABILITY
res - --class CRITICAL --attempt 2 --failure INSUFFICIENT_CAPABILITY --prev "0 0 0 0"; is model gpt-5.6-sol; is effort max          # model already at the ladder top: effort is the only real escalation
res - --class CRITICAL --attempt 3 --failure INSUFFICIENT_CAPABILITY --prev "0 1 0 1"; code 4; errs NO_ESCALATION_PATH
res - --class STANDARD --attempt 2 --failure CONTEXT_MISSING --prev "0 0 0 0"; is context_bytes 98304; is escalation ESCALATED_CONTEXT
res - --class CRITICAL --attempt 2 --failure CONTEXT_MISSING --prev "0 0 0 0"; is context_bytes 262144                      # 327680 capped at the hard limit, still a change
res - --class CRITICAL --attempt 3 --failure CONTEXT_MISSING --prev "0 0 1 1"; code 4; errs NO_ESCALATION_PATH               # at the ceiling: no fake escalation
res - --class STANDARD --attempt 2 --failure TRANSIENT --prev "0 0 0 0"; is model gpt-5.6-terra; is effort medium; is escalation RETRY_SAME_CAPABILITY; is esc_events 0
res - --class STANDARD --attempt 2 --failure SCOPE_VIOLATION --prev "0 0 0 0"; code 4; errs NON_RETRYABLE_FAILURE
res - --class STANDARD --attempt 2 --failure NONSENSE --prev "0 0 0 0"; code 2
res - --class STANDARD --attempt 2 --failure INSUFFICIENT_REASONING --prev "0 0 0 0" --model gpt-5.6-terra --effort medium; code 4; errs NO_ESCALATION_PATH   # pinned by the operator, never silently overridden

CASE="delegation follows independent areas, bounded by the class"
res "$(paths src/a docs/b tests/c)" --class COMPLEX --attempt 1; is delegation_limit 2; has delegation_reason INDEPENDENT_AREAS; has delegation_reason CAPPED_AT_CLASS_BOUND
res "$(paths src/a docs/b)" --class CRITICAL --attempt 1; is delegation_limit 2

CASE="case 8: same inputs -> same decision; policy revision is semantic, not a timestamp"
paths_f=$(paths .agents/x a/b)
res "$paths_f" --class COMPLEX --attempt 2 --failure INSUFFICIENT_CAPABILITY --prev "0 0 0 0"; first=$out
res "$paths_f" --class COMPLEX --attempt 2 --failure INSUFFICIENT_CAPABILITY --prev "0 0 0 0"; [ "$out" = "$first" ] || bad "$CASE: nondeterministic"; ok
is policy_version "$(sed -n 's/^  revision: *//p' "$root/.agents/config.yaml")"
mkcfg rev2 's/^  revision: 1$/  revision: 2/'; with EXEC_POLICY_CONFIG="$tmp/rev2.yaml" res "$paths_f" --class COMPLEX --attempt 2 --failure INSUFFICIENT_CAPABILITY --prev "0 0 0 0"
[ "$(printf '%s\n' "$first" | grep -v '^policy_version=')" = "$(printf '%s\n' "$out" | grep -v '^policy_version=')" ] || bad "$CASE: revision changed more than policy_version"; is policy_version 2
mkcfg inv 's/^      context_window_tokens: 272000/      context_window_tokens: 272000/; s/^        gpt-5.6-luna: efforts=.*/        gpt-5.6-luna: efforts=low,medium/'   # inventory edit, same semantics
with EXEC_POLICY_CONFIG="$tmp/inv.yaml" res - --class STANDARD --attempt 1; is policy_version 1

CASE="case 9: explanation is derived from the recorded codes and needs no model"
res "$paths_f" --class COMPLEX --attempt 2 --failure INSUFFICIENT_REASONING --prev "0 0 0 0"
expl=$(printf '%s\n' "$out" | PATH=/usr/bin:/bin sh "$ep" explain)
case "$expl" in *"effort_reason: ESCALATED_REASONING"*"model_reason: SENSITIVE_PATHS"*|*"model_reason: CLASS_TIER"*) ok ;; *) bad "$CASE: $expl" ;; esac
case "$expl" in *"no text for"*) bad "$CASE: a reason code has no text" ;; esac; ok
for c in TRIVIAL STANDARD COMPLEX CRITICAL; do res "$paths_f" --class $c --attempt 1; printf '%s\n' "$out" | sh "$ep" explain | grep -q 'no text for' && bad "$CASE: $c has an unexplained code"; ok; done

CASE="standalone: the session owns model/effort; overrides for them are rejected, the rest still resolves"
with TOPO=standalone res - --class COMPLEX --attempt 1; code 0; is provider session; is model session; is effort session; is cache_strategy none
is context_bytes 98304; is delegation_limit 1; has delegation_reason SINGLE_AREA; is planning architected
with TOPO=standalone res - --class COMPLEX --attempt 1 --model gpt-5.6-sol; code 3; errs OVERRIDE_NOT_APPLICABLE
with TOPO=standalone res - --class COMPLEX --attempt 2 --failure INSUFFICIENT_REASONING --prev "0 0 0 0"; code 4; errs NO_ESCALATION_PATH
with TOPO=standalone res - --class COMPLEX --attempt 2 --failure CONTEXT_MISSING --prev "0 0 0 0"; is context_bytes 196608

CASE="cache: no fake TTL"
res - --class STANDARD --attempt 1; is cache_strategy stable_prefix; is cache_ttl none; has cache_reason NO_EXPLICIT_CACHE_CONTROL
mkcfg ttl 's/^      cache_control: none/      cache_control: ttl/'; with EXEC_POLICY_CONFIG="$tmp/ttl.yaml" res - --class STANDARD --attempt 1; code 2; errs "fake TTL"

CASE="config validation fails loudly"
mkcfg badforb 's/^  effort_order: .*/  effort_order: low medium high ultra/'; with EXEC_POLICY_CONFIG="$tmp/badforb.yaml" res - --class STANDARD --attempt 1; code 2; errs forbidden
mkcfg badeff 's/^        gpt-5.6-luna: efforts=.*/        gpt-5.6-luna: efforts=low,turbo/'; with EXEC_POLICY_CONFIG="$tmp/badeff.yaml" res - --class STANDARD --attempt 1; code 2; errs turbo
res - --class UNKNOWN --attempt 1; code 2

CASE="capabilities are honest"
mkdir -p "$tmp/cc"; cat > "$tmp/cc/ok.json" <<'J'
{"models":[
 {"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},
 {"slug":"gpt-5.6-terra","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
 {"slug":"gpt-5.6-sol","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]}]}
J
if command -v jq >/dev/null 2>&1; then
  with CODEX_MODELS_CACHE="$tmp/cc/ok.json" sh "$ep" check-capabilities >/dev/null; ok
  sed 's/"gpt-5.6-sol"/"gpt-other"/' "$tmp/cc/ok.json" > "$tmp/cc/gone.json"
  if with CODEX_MODELS_CACHE="$tmp/cc/gone.json" sh "$ep" check-capabilities >/dev/null 2>&1; then bad "$CASE: a model missing from the runtime passed"; fi; ok
fi

CASE="no downstream policy: model ids and effort levels live only in the config"
if grep -nE 'gpt-[0-9]|model_reasoning_effort=(low|medium|high|xhigh|max)' "$root/scripts/"*.sh | grep -v 'exec-policy-test.sh\|lifecycle-test.sh\|# ' | grep -v '^scripts/agent.sh:.*_test'; then bad "$CASE: a script hardcodes a model or effort"; fi; ok
if grep -n 'exec-policy.sh' "$root/scripts/"*.sh | grep -vE 'exec-policy(-test)?\.sh:|agent\.sh:|lifecycle-test\.sh:'; then bad "$CASE: only agent.sh may call the resolver"; fi; ok

echo "execution policy tests passed ($n assertions)"

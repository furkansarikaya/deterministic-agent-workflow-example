#!/bin/sh
# Canonical implementation_worker invocation path — this repository's Codex
# adapter for `orchestrated` execution topology (see .agents/WORKFLOW.md's
# "Execution topology" section). It has no reason to run at all against a
# run whose resolved topology is `standalone`: that topology's full_lifecycle
# agent implements its own RED/GREEN evidence directly, never via a worker.
#
# This is the ONLY sanctioned way to run implementation_worker under
# orchestrated topology: it shells out to the real `codex exec` CLI (the
# same binary/mechanism that actually performed KW-001's IMPLEMENT phase in
# the KnowWeave sibling repository — see the network-sandbox lesson encoded
# below) with AGENT_ROLE=implementation_worker set for that subprocess only.
# It never falls back to doing the implementation itself: a missing `codex`
# binary, a non-zero exit, or no output is a hard failure, and the caller (a
# full_lifecycle orchestrator) must not treat that as license to implement
# the change directly.
#
# Model/reasoning-effort selection is deliberately NOT pinned here: unless
# --model/--effort is explicitly passed, `codex exec` resolves both from the
# user's own ~/.codex/config.toml, exactly as it already does for an
# interactive invocation. Pinning a specific model into version control
# would silently diverge from whatever the operator's Codex install is
# actually configured to run.
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
usage() { echo "usage: $0 <TASK-ID> <PHASE> --network <required|not-required> --prompt-file <path> [--model <name>] [--effort <level>]" >&2; exit 2; }

task_id=${1:?}; phase=${2:?}; shift 2
network='' prompt_file='' model='' effort=''
while [ $# -gt 0 ]; do
  case "$1" in
    --network) network=${2:?}; shift 2 ;;
    --prompt-file) prompt_file=${2:?}; shift 2 ;;
    --model) model=${2:?}; shift 2 ;;
    --effort) effort=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
case "$phase" in RED|GREEN|REFACTOR|FIX) ;; *) echo "invalid phase: $phase (want RED|GREEN|REFACTOR|FIX)" >&2; exit 2 ;; esac
case "$network" in required|not-required) ;; *) echo "--network must be 'required' or 'not-required' (declare it from EVIDENCE.md, don't guess)" >&2; exit 2 ;; esac
[ -n "$prompt_file" ] && [ -f "$prompt_file" ] || usage

dir="$root/.agents/runs/$task_id"
[ -d "$dir" ] || { echo "worker-run: no such run: $task_id" >&2; exit 1; }

# Checked before even looking for the codex binary: this is a more
# fundamental precondition ("does this run want a worker at all?") than
# tooling availability, and should fail with a clear semantic reason rather
# than a misleading "codex not found" in an environment that simply never
# needed codex for a standalone-topology run. Same resolution order as
# agent.sh's resolve_topology: RUN.yaml wins over .agents/config.yaml's
# default_topology; neither being valid is a hard failure, never a guess.
topology=$(sed -n '/^execution:$/,/^[^ ]/p' "$dir/RUN.yaml" | sed -n 's/^[[:space:]]*topology: *//p' | head -1 | tr -d '"')
case "$topology" in
  standalone|orchestrated) ;;
  *) topology=$(sed -n 's/^default_topology: *//p' "$root/.agents/config.yaml" | head -1 | tr -d '"') ;;
esac
case "$topology" in
  orchestrated) ;;
  standalone) echo "worker-run: run $task_id resolves to standalone execution topology; this run's full_lifecycle agent implements RED/GREEN itself and must not invoke worker-run.sh" >&2; exit 1 ;;
  *) echo "worker-run: could not resolve a valid execution topology for $task_id (set execution.topology or .agents/config.yaml's default_topology)" >&2; exit 1 ;;
esac

command -v codex >/dev/null 2>&1 || { echo "worker-run: codex CLI not found on PATH; refusing to fall back to self-implementation" >&2; exit 1; }

state=$(sed -n '/^handoff:$/,/^[^ ]/p' "$dir/RUN.yaml" | sed -n 's/^[[:space:]]*state: *//p' | head -1 | tr -d '"')
[ "$state" = IMPLEMENTING ] || { echo "worker-run: run $task_id is not in IMPLEMENTING (state: $state); establish that handoff first" >&2; exit 1; }

sandbox=workspace-write
net_flag=false
[ "$network" = required ] && net_flag=true

log_dir="$dir/worker-evidence"; mkdir -p "$log_dir"
seq=1
while [ -e "$log_dir/$phase-invocation-$seq.log" ]; do seq=$((seq + 1)); done
log_file="$log_dir/$phase-invocation-$seq.log"

# `codex exec` is already non-interactive/non-approval by design (no
# --full-auto equivalent needed or offered for this subcommand); the
# sandbox mode and its network flag are the actual controls we need.
#
# `--add-dir "$log_dir"` is required: `codex exec --sandbox workspace-write`
# denies writes under dot-prefixed directories (`.agents/**`) even though
# they are inside the workdir it otherwise treats as writable (observed and
# reproduced against a real `codex exec` invocation — see
# .agents/WORKFLOW.md's "Worker evidence and the sandbox boundary" section).
# `agent.sh worker-evidence` writes exactly one file, under this run's own
# `.agents/runs/<TASK-ID>/worker-evidence/`, and nowhere else under
# `.agents/` — so this grant is scoped to that single directory, not to
# `.agents/**` as a whole. It never widens to TASK.md/EVIDENCE.md/PLAN.md/
# RUN.yaml or any other run's directory: `implementation_worker` still
# cannot write those, sandboxed or not.
set -- exec --sandbox "$sandbox" --add-dir "$log_dir"
[ -n "$model" ] && set -- "$@" --model "$model"
[ -n "$effort" ] && set -- "$@" --config "model_reasoning_effort=$effort"
set -- "$@" --config "sandbox_workspace_write.network_access=$net_flag"

# Bracket the worker run with tree attestation. For a run with the
# lifecycle_gates policy under orchestrated topology, `window-open` proves the
# application/test tree is still exactly what the previous worker window left
# (refusing to start otherwise, so an edit made outside the worker cannot be
# absorbed into a worker window) and prints its fingerprint; `window-close`,
# run below whether or not codex succeeds, records the before/after pair as a
# chained WINDOW record. Both are measured here, by the invoking orchestrator
# process, never by the worker, and both are no-ops for any run that does not
# use that policy (see agent.sh's verify_mutation_ownership).
tree_before=$("$root/scripts/agent.sh" window-open "$task_id") || { echo "worker-run: refusing to start a worker window: the application/test tree is not the last attested state (see the message above); undo the unattributed change first" >&2; exit 1; }

echo "worker-run: invoking codex $* (AGENT_ROLE=implementation_worker, network=$network)" | tee "$log_file"
status=0
AGENT_ROLE=implementation_worker CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" codex "$@" < "$prompt_file" >> "$log_file" 2>&1 || status=$?
"$root/scripts/agent.sh" window-close "$task_id" "$tree_before" "$status" >> "$log_file" 2>&1 || { echo "worker-run: could not record the worker window (unattributed mutation?); log: ${log_file#$root/}" >&2; exit 1; }
if [ "$status" -eq 0 ]; then
  echo "worker-run: codex exec completed (exit 0); log: ${log_file#$root/}"
else
  echo "worker-run: codex exec FAILED (exit $status); task remains incomplete, not implemented by full_lifecycle as a fallback; log: ${log_file#$root/}" >&2
  exit "$status"
fi

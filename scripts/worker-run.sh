#!/bin/sh
# Canonical Claude -> Codex implementation_worker invocation path.
#
# This is the ONLY sanctioned way to run implementation_worker: it shells
# out to the real `codex exec` CLI (the same binary/mechanism that actually
# performed KW-001's IMPLEMENT phase in the KnowWeave sibling repository —
# see the network-sandbox lesson encoded below) with AGENT_ROLE=
# implementation_worker set for that subprocess only. It never falls back to
# doing the implementation itself: a missing `codex` binary, a non-zero
# exit, or no output is a hard failure, and the caller (a full_lifecycle
# session) must not treat that as license to implement the change directly.
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

command -v codex >/dev/null 2>&1 || { echo "worker-run: codex CLI not found on PATH; refusing to fall back to self-implementation" >&2; exit 1; }

dir="$root/.agents/runs/$task_id"
[ -d "$dir" ] || { echo "worker-run: no such run: $task_id" >&2; exit 1; }
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
set -- exec --sandbox "$sandbox"
[ -n "$model" ] && set -- "$@" --model "$model"
[ -n "$effort" ] && set -- "$@" --config "model_reasoning_effort=$effort"
set -- "$@" --config "sandbox_workspace_write.network_access=$net_flag"

echo "worker-run: invoking codex $* (AGENT_ROLE=implementation_worker, network=$network)" | tee "$log_file"
if AGENT_ROLE=implementation_worker CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" codex "$@" < "$prompt_file" >> "$log_file" 2>&1; then
  echo "worker-run: codex exec completed (exit 0); log: ${log_file#$root/}"
else
  status=$?
  echo "worker-run: codex exec FAILED (exit $status); task remains incomplete, not implemented by full_lifecycle as a fallback; log: ${log_file#$root/}" >&2
  exit "$status"
fi

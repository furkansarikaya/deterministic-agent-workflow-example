#!/bin/sh
# event.sh: one optional workflow-event/1 (observer only).
#
#   event.sh --root DIR --task ID --event E --stage S --status T [--gate G] [--attempt N]
#            [--role R] [--topology T] [--findings-open N] [--loop N] [--fingerprint H]
#
# Fail-open and bounded: no AGENT_WORKFLOW_EVENTS_URL, no curl, a bad argument, an
# unreachable or slow receiver, all end in silence and exit status 0. At most one POST,
# no retries, a hard limit of 0.3 s per POST (whole seconds only on a curl that rejects
# fractions). An event carries identifiers, enums, counters and hashes only: no prose, titles, paths, source, prompts or findings text. Every value
# is checked against its enum or pattern, and one invalid value drops the whole event.
# Needs sh, date and (optional) curl.
#
# Contract (this header is its only definition). Schema "workflow-event/1", one JSON object:
#   schema, event (stage|gate|attempt|remediation|outcome), runRef (the task id), seq, stage
#   (discover|evidence|plan|implement|review|qa|verify|code_done|knowledge|done), status
#   (started|passed|failed|blocked|skipped|completed); optional: gate (review|qa|verify), attempt,
#   role, topology (standalone|orchestrated), findingsOpen, loop, fingerprint (sha256 hex);
#   then at (ISO time, .000 ms), and providerSession {provider claude|codex, sessionId} only when
#   AGENT_SESSION_PROVIDER and AGENT_SESSION_ID are set (unverified).
# role is the role that emitted the event (the invoking AGENT_ROLE), never one merely expected to act.
# seq is monotonic per run, kept in .agents/runtime/events/; a missing counter is seeded from the
# epoch seconds. runRef MUST be unique across the repositories reporting to one collector.

url=${AGENT_WORKFLOW_EVENTS_URL:-}
case "$url" in http://?*|https://?*) ;; *) exit 0 ;; esac
case "$url" in *[[:space:]]*) exit 0 ;; esac
command -v curl >/dev/null 2>&1 || exit 0

root=.; run=''; event=''; stage=''; status=''; gate=''; role=''; topology=''; fingerprint=''
attempt=-1; findings=-1; loop=-1
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || exit 0
  case "$1" in
    --root) root=$2 ;; --task) run=$2 ;; --event) event=$2 ;; --stage) stage=$2 ;; --status) status=$2 ;;
    --gate) gate=$2 ;; --role) role=$2 ;; --topology) topology=$2 ;; --fingerprint) fingerprint=$2 ;;
    --attempt) attempt=$2 ;; --findings-open) findings=$2 ;; --loop) loop=$2 ;;
    *) exit 0 ;;
  esac
  shift 2
done

# ---- validation: every value against its enum or pattern ------------------------
case "$run" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
[ "${#run}" -le 128 ] || exit 0
case "$event" in stage|gate|attempt|remediation|outcome) ;; *) exit 0 ;; esac
case "$stage" in discover|evidence|plan|implement|review|qa|verify|code_done|knowledge|done) ;; *) exit 0 ;; esac
case "$status" in started|passed|failed|blocked|skipped|completed) ;; *) exit 0 ;; esac
case "$gate" in ''|review|qa|verify) ;; *) exit 0 ;; esac
case "$role" in ''|full_lifecycle|implementation_worker|independent_reviewer|independent_qa|independent_verifier|explorer|architect) ;; *) exit 0 ;; esac
case "$topology" in ''|standalone|orchestrated) ;; *) exit 0 ;; esac
case "$fingerprint" in '') ;; *[!0-9a-f]*) exit 0 ;; *) [ "${#fingerprint}" -eq 64 ] || exit 0 ;; esac
for n in "$attempt" "$findings" "$loop"; do
  case "$n" in -*) ;; ''|*[!0-9]*) exit 0 ;; esac    # a negative number means "omit"
done

# ---- seq: monotonic per run, kept outside run state in the ignored runtime dir ---
dir=$root/.agents/runtime/events
mkdir -p "$dir" 2>/dev/null || exit 0
seq=0; [ ! -r "$dir/$run.seq" ] || read -r seq < "$dir/$run.seq" || seq=0
case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
# A missing or unreadable counter is seeded from the epoch seconds, so a recreated counter (or another checkout
# reusing the task id) never replays small seq values that a collector has already seen. `date` runs here only,
# after the curl and URL checks above.
[ "$seq" -gt 0 ] || { seq=$(date +%s 2>/dev/null) || exit 0; case "$seq" in ''|*[!0-9]*) exit 0 ;; esac; }
seq=$((seq + 1))
printf '%s\n' "$seq" > "$dir/$run.seq" 2>/dev/null || exit 0

# ---- the event, fields in schema order -------------------------------------------
body="{\"schema\":\"workflow-event/1\",\"event\":\"$event\",\"runRef\":\"$run\",\"seq\":$seq,\"stage\":\"$stage\",\"status\":\"$status\""
[ -z "$gate" ] || body="$body,\"gate\":\"$gate\""
case "$attempt" in -*) ;; *) body="$body,\"attempt\":$attempt" ;; esac
[ -z "$role" ] || body="$body,\"role\":\"$role\""
[ -z "$topology" ] || body="$body,\"topology\":\"$topology\""
case "$findings" in -*) ;; *) body="$body,\"findingsOpen\":$findings" ;; esac
case "$loop" in -*) ;; *) body="$body,\"loop\":$loop" ;; esac
[ -z "$fingerprint" ] || body="$body,\"fingerprint\":\"$fingerprint\""
body="$body,\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\""
# Provider correlation is unverified: it is whatever the caller put in the environment.
prov=${AGENT_SESSION_PROVIDER:-}; sid=${AGENT_SESSION_ID:-}
case "$prov" in
  claude|codex)
    case "$sid" in ''|*[!A-Za-z0-9_.:-]*) ;; *) [ "${#sid}" -gt 128 ] || body="$body,\"providerSession\":{\"provider\":\"$prov\",\"sessionId\":\"$sid\"}" ;; esac ;;
esac
body="$body}"

# ---- one POST: silent, no retry, no proxy, hard time limit ------------------------
post() { curl -s -o /dev/null --noproxy '*' --retry 0 --connect-timeout "$1" --max-time "$2" \
  -X POST -H 'Content-Type: application/json' --data-binary "$body" -- "$url" >/dev/null 2>&1; }
# 0.3 s overall (the spec is 300 ms). A curl that rejects fractional times exits 2 before sending anything:
# only then retry once with whole seconds, silently.
post 0.2 0.3 || { [ "$?" -ne 2 ] || post 1 1 || true; }
exit 0

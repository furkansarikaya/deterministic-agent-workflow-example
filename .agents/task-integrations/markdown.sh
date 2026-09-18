#!/bin/sh
# Markdown task-integration adapter.
#
# Contract (see .agents/task-integrations/README.md): a task-integration
# adapter implements exactly two operations and knows nothing about the
# deterministic control plane beyond a task ID and a report file/receipt.
#
#   <adapter>.sh publish <TASK-ID> <report-file>   -> prints a receipt
#   <adapter>.sh verify  <TASK-ID> <receipt>       -> exit 0 iff still present
#
# This adapter's "native activity/history surface" is the task's own
# `local_markdown` source file (the same file `task_source.path` in RUN.yaml
# already points at) — it appends the report under a delimited, idempotent
# section rather than creating a second parallel document. Any other
# adapter (an issue tracker, a different task system) implements the same
# two operations against its own surface; agent.sh never needs to know which.
set -eu
root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
op=${1:?usage: markdown.sh <publish|verify> ...}

task_source_path() {
  id=$1 run="$root/.agents/runs/$id/RUN.yaml"
  awk '/^task_source:$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && /^[[:space:]]*path:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$run"
}
hash_stdin() { shasum -a 256 | awk '{print $1}'; }

case "$op" in
  publish)
    id=${2:?usage: markdown.sh publish <TASK-ID> <report-file>}
    report=${3:?usage: markdown.sh publish <TASK-ID> <report-file>}
    path=$(task_source_path "$id"); [ -n "$path" ] || { echo "markdown adapter: no task_source.path for $id" >&2; exit 1; }
    target="$root/$path"
    [ -f "$target" ] || { echo "markdown adapter: task source file missing: $path" >&2; exit 1; }
    begin="<!-- COMPLETION-REPORT:BEGIN:$id -->"
    end="<!-- COMPLETION-REPORT:END:$id -->"
    tmp=$(mktemp "${TMPDIR:-/tmp}/markdown-adapter.XXXXXX")
    if grep -Fq "$begin" "$target"; then
      awk -v b="$begin" -v e="$end" -v rf="$report" '
        $0 == b { print; while ((getline line < rf) > 0) print line; skip=1; next }
        $0 == e { print; skip=0; next }
        skip { next }
        { print }
      ' "$target" > "$tmp"
    else
      cp "$target" "$tmp"
      {
        printf '\n## Completion Report\n\n%s\n' "$begin"
        cat "$report"
        printf '%s\n' "$end"
      } >> "$tmp"
    fi
    mv "$tmp" "$target"
    body_hash=$(cat "$report" | hash_stdin)
    printf '%s#%s\n' "$path" "$body_hash"
    ;;
  verify)
    id=${2:?usage: markdown.sh verify <TASK-ID> <receipt>}
    receipt=${3:?usage: markdown.sh verify <TASK-ID> <receipt>}
    path=${receipt%%#*}; expected_hash=${receipt#*#}
    [ -n "$path" ] && [ -n "$expected_hash" ] && [ "$path" != "$receipt" ] || { echo "markdown adapter: malformed receipt: $receipt" >&2; exit 1; }
    target="$root/$path"
    [ -f "$target" ] || { echo "markdown adapter: task source file missing: $path" >&2; exit 1; }
    begin="<!-- COMPLETION-REPORT:BEGIN:$id -->"
    end="<!-- COMPLETION-REPORT:END:$id -->"
    actual_hash=$(awk -v b="$begin" -v e="$end" '
      $0 == b { inside=1; next } $0 == e { inside=0; next } inside { print }
    ' "$target" | hash_stdin)
    [ -n "$actual_hash" ] || { echo "markdown adapter: no completion-report section found for $id in $path" >&2; exit 1; }
    [ "$actual_hash" = "$expected_hash" ] || { echo "markdown adapter: completion-report content in $path no longer matches published receipt" >&2; exit 1; }
    ;;
  *) echo "usage: markdown.sh <publish|verify> ..." >&2; exit 2 ;;
esac

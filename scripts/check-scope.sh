#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
validate=false
if [ "${1:-}" = --validate-plan ]; then validate=true; shift; fi
id=${1:?usage: $0 '[--validate-plan] <TASK-ID>'}
plan=$root/.agents/runs/$id/PLAN.md
[ -f "$plan" ] || { echo "plan not found: $plan" >&2; exit 1; }

mappings=$(awk '
  /^scope:$/ { in_scope=1; next }
  in_scope && /^---$/ { exit }
  in_scope && /^  - path: / { path=$0; sub(/^  - path: /, "", path); next }
  in_scope && /^    criteria: \[/ { c=$0; sub(/^    criteria: \[/, "", c); sub(/\]$/, "", c); if (path == "" || c == "") { bad=1 } else print path "|" c; path="" }
  END { if (bad || path != "") exit 1 }
' "$plan") || { echo "invalid scope mapping in $plan" >&2; exit 1; }
[ -n "$mappings" ] || { echo "scope mapping missing" >&2; exit 1; }
if [ "$validate" = true ]; then echo "plan mapping valid: $id"; exit 0; fi

changes=$( { git -C "$root" diff --no-renames --name-only; git -C "$root" diff --cached --no-renames --name-only; git -C "$root" ls-files --others --exclude-standard; } | sort -u)
unexpected=""
for changed in $changes; do
  if ! printf '%s\n' "$mappings" | cut -d '|' -f1 | grep -Fxq "$changed"; then unexpected="${unexpected}${changed}\n"; fi
done
if [ -n "$unexpected" ]; then
  echo "unexpected or unmapped changed paths:" >&2
  printf '%b' "$unexpected" >&2
  exit 1
fi
echo "scope check passed: $id"


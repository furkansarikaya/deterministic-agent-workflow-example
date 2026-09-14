#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <PLAN.md>" >&2
  exit 2
fi

plan_file=$1
if [ ! -f "$plan_file" ]; then
  echo "plan not found: $plan_file" >&2
  exit 2
fi

expected=$(awk '
  /^## Expected changed files$/ { collecting=1; next }
  /^## / { if (collecting) exit }
  collecting && /^- / { sub(/^- /, ""); print }
' "$plan_file" | sort)
actual=$( { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } | sort -u)
unexpected=""
for changed in $actual; do
  if ! printf '%s\n' "$expected" | grep -Fxq "$changed"; then
    unexpected="${unexpected}${changed}\n"
  fi
done

if [ -n "$unexpected" ]; then
  echo "unexpected changed files:" >&2
  printf '%b' "$unexpected" >&2
  exit 1
fi

echo "scope check passed: all changed files are listed in $plan_file"

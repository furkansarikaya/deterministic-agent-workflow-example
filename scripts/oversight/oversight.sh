#!/bin/sh
# oversight.sh: read-only projection of one run directory.
#
#   oversight.sh model|summary|report --root DIR --task ID [--out FILE]
#
# run state -> model records (model.awk) -> JSON (json.awk), CLI summary (summary.awk)
# or one HTML page (svg.awk + report.awk). It never writes run state. Needs only
# sh, awk, git and standard tools (see .agents/OVERSIGHT.md). Every awk program runs
# with LC_ALL=C so output is byte-identical on BSD awk, mawk and gawk.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
US=$(printf '\037')
LC_ALL=C; export LC_ALL

fail() { echo "oversight: $*" >&2; exit 1; }
usage() { echo "usage: oversight.sh <model|summary|report> --root DIR --task ID [--out FILE]" >&2; exit 2; }

[ $# -ge 1 ] || usage
cmd=$1; shift
root=.; task=''; out=''
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--task|--out) [ $# -ge 2 ] || usage; opt=${1#--}; val=$2; shift 2 ;;
    --root=*|--task=*|--out=*) opt=${1#--}; opt=${opt%%=*}; val=${1#*=}; shift ;;
    *) usage ;;
  esac
  case "$opt" in root) root=$val ;; task) task=$val ;; out) out=$val ;; esac
done
case "$cmd" in model|summary|report) ;; *) fail "unknown command: $cmd" ;; esac
root=$(CDPATH= cd "$root" && pwd) || fail "no such directory: $root"
case "$task" in ''|*[!A-Za-z0-9_-]*) fail "invalid task id" ;; esac
rd=$root/.agents/runs/$task
[ -r "$rd/RUN.yaml" ] || fail "run not found: $task"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/oversight.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# ---- diffstat: counts only, through git ---------------------------------------

# newest_manifest: the manifest of the highest-numbered gate record that has one.
newest_manifest() {
  nm_best=''; nm_n=-1
  for nm_f in "$rd"/gates/[0-9]*-*.manifest; do
    [ -f "$nm_f" ] || continue
    nm_b=${nm_f##*/}
    case "$nm_b" in *-REVIEW.manifest|*-QA.manifest|*-VERIFY.manifest|*-REOPEN.manifest) ;; *) continue ;; esac
    [ -f "${nm_f%.manifest}.yaml" ] || continue
    nm_num=${nm_b%%-*}
    case "$nm_num" in ''|*[!0-9]*) continue ;; esac
    if [ "$nm_num" -ge "$nm_n" ] 2>/dev/null; then nm_best=$nm_f; nm_n=$nm_num; fi
  done
  [ -z "$nm_best" ] || printf '%s\n' "$nm_best"
}

# diff_records: `diffstate ok|none` and `diff PATH ADDED DELETED` lines for the changed files.
diff_records() {
  dr_base=$(awk '/^repository:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $1 == "base_sha:" { gsub(/"/, "", $2); print $2; exit }' "$rd/RUN.yaml")
  case "$dr_base" in ''|PENDING|pending) return 0 ;; esac
  dr_man=$(newest_manifest) || return 0
  [ -n "$dr_man" ] || return 0
  sed -n 's/^\(.\{1,\}\)|[^|]*$/\1/p' "$dr_man" > "$tmp/paths"
  [ -s "$tmp/paths" ] || return 0
  g() { git --no-optional-locks -C "$root" -c core.quotePath=false "$@"; }
  if g ls-files > "$tmp/tracked" 2>/dev/null && g diff --numstat --no-renames "$dr_base" > "$tmp/numstat" 2>/dev/null; then
    printf 'diffstate%sok\n' "$US"
    awk -f "$here/diffstat.awk" "$tmp/paths" "$tmp/tracked" "$tmp/numstat" > "$tmp/joined"
    awk -F "$US" '$1 == "diff"' "$tmp/joined"
    # an untracked file has no diff against the base: every line counts as added (binary files are skipped)
    awk -F "$US" '$1 == "untracked" { print $2 }' "$tmp/joined" | while IFS= read -r dr_p; do
      [ -f "$root/$dr_p" ] || continue
      tr -d '\000' < "$root/$dr_p" | cmp -s - "$root/$dr_p" || continue
      printf 'diff%s%s%s%s%s0\n' "$US" "$dr_p" "$US" "$(awk 'END { print NR }' "$root/$dr_p")" "$US"
    done
  else
    printf 'diffstate%snone\n' "$US"
  fi
}

# index_records: what model.awk reads: where the run is and which files to open.
index_records() {
  printf 'root%s%s\ntask%s%s\n' "$US" "$root" "$US" "$task"
  for ix_f in "$rd"/gates/*.yaml; do if [ -f "$ix_f" ]; then printf 'gate%s%s\n' "$US" "$ix_f"; fi; done
  for ix_f in "$rd"/worker-evidence/*.yaml; do if [ -f "$ix_f" ]; then printf 'wevid%s%s\n' "$US" "$ix_f"; fi; done
  for ix_f in "$rd"/decisions/*.decision; do if [ -f "$ix_f" ]; then printf 'decision%s%s\n' "$US" "$ix_f"; fi; done
  diff_records
}

index_records > "$tmp/index"
awk -f "$here/lib.awk" -f "$here/model.awk" < "$tmp/index" > "$tmp/model" || fail "could not build the model for $task"

report_path=$root/.agents/runtime/reports/$task.html
rel() { case "$1" in "$root"/*) printf '%s\n' "${1#"$root"/}" ;; *) printf '%s\n' "$1" ;; esac; }

case "$cmd" in
  model)
    awk -f "$here/lib.awk" -f "$here/mload.awk" -f "$here/json.awk" < "$tmp/model" ;;
  summary)
    rp=''; if [ -f "$report_path" ]; then rp=$(rel "$report_path"); fi
    awk -v REPORT="$rp" -f "$here/lib.awk" -f "$here/mload.awk" -f "$here/summary.awk" < "$tmp/model" ;;
  report)
    out_arg=$out
    [ -n "$out" ] || out=$report_path
    case "$out" in /*) ;; *) out=$PWD/$out ;; esac
    # a report is never written into run state: resolve the path physically, then refuse .agents/runs/
    out=$(printf '%s\n' "$out" | awk '{ n = split($0, a, "/"); m = 0
      for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue
        if (a[i] == "..") { if (m > 0) m--; continue }
        p[++m] = a[i] }
      s = ""; for (i = 1; i <= m; i++) s = s "/" p[i]; print (s == "" ? "/" : s) }')
    od=${out%/*}; ob=${out##*/}; orest=
    while [ ! -d "${od:-/}" ]; do orest=/${od##*/}$orest; od=${od%/*}; done
    od=$(cd "${od:-/}" && pwd -P); target=$od$orest/$ob
    rroot=$(cd "$root" && pwd -P)
    # A report is never written into run state, and never over a tracked file. The checks compare
    # inodes (`-ef`), not strings, so letter case, symlinks and `..` cannot get around them.
    runs=$rroot/.agents/runs
    shown() { case "$1" in "$rroot"/*) printf '%s\n' "${1#"$rroot"/}" ;; *) if [ -n "$out_arg" ]; then printf '%s\n' "$out_arg"; else printf '%s\n' "$1"; fi ;; esac; }
    [ ! -L "$target" ] || fail "refusing to write a report through a symlink: $(shown "$target")"
    [ ! -d "$target" ] || fail "refusing to write a report over a directory: $(shown "$target")"
    walk=$target
    while [ -n "$walk" ]; do
      if [ -e "$walk" ] && [ "$walk" -ef "$runs" ]; then fail "refusing to write a report inside .agents/runs/ (run state is never modified)"; fi
      walk=${walk%/*}
    done
    if [ -f "$target" ]; then
      for rf in "$runs"/* "$runs"/*/* "$runs"/*/*/*; do
        if [ -f "$rf" ] && [ "$rf" -ef "$target" ]; then fail "refusing to write a report over run state"; fi
      done
      git --no-optional-locks -C "$rroot" ls-files --error-unmatch -- "${target#"$rroot"/}" >/dev/null 2>&1 \
        && fail "refusing to overwrite a tracked file: $(shown "$target")"
      git --no-optional-locks -C "$rroot" -c core.quotePath=false ls-files 2>/dev/null | while IFS= read -r tf; do
        if [ -f "$rroot/$tf" ] && [ "$rroot/$tf" -ef "$target" ]; then echo tracked; break; fi
      done > "$tmp/tracked-hit"
      [ ! -s "$tmp/tracked-hit" ] || fail "refusing to overwrite a tracked file: $(shown "$target")"
    fi
    mkdir -p "${target%/*}" || fail "cannot create the report directory"
    # a unique temp file in the target's own directory (so the final mv is atomic): a planted
    # `$target.tmp` symlink is never followed
    rtmp=$(mktemp "${target%/*}/.oversight-report.XXXXXX") || fail "cannot create a temporary report file"
    trap 'rm -rf "$tmp" "$rtmp"' EXIT
    awk -v DIR="$here" -f "$here/lib.awk" -f "$here/mload.awk" -f "$here/svg.awk" -f "$here/report.awk" < "$tmp/model" > "$rtmp" || { rm -f "$rtmp"; fail "report rendering failed"; }
    mv -f "$rtmp" "$target" || { rm -f "$rtmp"; fail "cannot write the report"; }
    echo "report written: $(shown "$target")"
    # the report event names the first stage not yet completed; a no-op unless AGENT_WORKFLOW_EVENTS_URL is set
    stage=$(awk -F "$US" '$1 == "stage" && $3 == "stage" { nm[$2] = $4; if ($2 + 0 > n) n = $2 + 0 }
      $1 == "stage" && $3 == "status" { st[$2] = $4 }
      END { for (i = 1; i <= n; i++) if (st[i] != "completed" && st[i] != "passed" && st[i] != "skipped") { print nm[i]; exit } print "done" }' "$tmp/model")
    sh "$here/event.sh" --root "$root" --task "$task" --event report --stage "$stage" --status completed --report-available true >/dev/null 2>&1 || true ;;
esac

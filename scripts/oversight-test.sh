#!/bin/sh
# Tests for the optional presentation layer: `agent.sh summary`, `agent.sh report`, report cleanup and
# retention, the fail-open event emitter, and the invariant that deleting all of it leaves the
# deterministic workflow tests passing. Fixtures come from scripts/lifecycle-test.sh (sourced, not run).
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
LC_LIB=1 . "$here/lifecycle-test.sh"            # defines root, base, scaffold, solo, pass_all, gate_*, finish_done, A, AS
TMPDIR=$base/tmp; export TMPDIR; mkdir -p "$TMPDIR"
bad() { echo "FAIL: $*" >&2; exit 1; }
has() { printf '%s' "$2" | grep -Fq -- "$3" || bad "$1 (missing: $3)"; }
lacks() { if printf '%s' "$2" | grep -Fq -- "$3"; then bad "$1 (unexpected: $3)"; fi; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done | shasum -a 256 | cut -d' ' -f1); }
rdir() { printf '%s/agent-oversight-%s\n' "$TMPDIR" "$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-16)"; }
drive() { # a standalone run, frozen and IMPLEMENTING, to CODE_DONE (the marker is planted in a changed source file)
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt "impl: SRC_MARKER_4f9c21 lookup"
  A handoff LC IMPLEMENTED >/dev/null; pass_all self; A handoff LC CODE_DONE >/dev/null
}
# One brace/bracket balanced, single-line JSON object with no raw control byte and no unterminated string.
json_ok() { awk 'NR>1{exit 1} { if ($0 ~ /[[:cntrl:]]/) exit 1; d=0; s=0; e=0
  for (i=1;i<=length($0);i++) { c=substr($0,i,1)
    if (s) { if (e) e=0; else if (c=="\\") e=1; else if (c=="\"") s=0; continue }
    if (c=="\"") s=1; else if (c=="{"||c=="[") d++; else if (c=="}"||c=="]") d--; if (d<0) exit 1 }
  exit !(d==0 && s==0 && $0 ~ /^\{.*\}$/) }'; }
data_of() { sed -n '/id="oversight-data"/,/^<\/script>/p' "$1" | sed '1d;$d'; }

# --- summary: content from a real lifecycle, including a failed gate and its fix -------------------
scaffold standalone false
solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt "impl: SRC_MARKER_4f9c21 lookup"
A handoff LC IMPLEMENTED >/dev/null
gate_fail full_lifecycle REVIEW impl.txt
s=$(A summary LC); has "summary status" "$s" 'STATUS: ' ; has "open finding" "$s" 'FINDINGS: open 1, failing gate records 1'
has "review failed" "$s" 'REVIEW: fail (attempts 1)'; has "qa has no record" "$s" 'QA: unavailable'; has "classification" "$s" 'CLASS/TOPOLOGY: COMPLEX / standalone'
has "changed count" "$s" 'CHANGED: 2'; has "no report yet" "$s" 'REPORT: unavailable'; has "task line" "$s" 'TASK: LC'
A handoff LC IMPLEMENTING >/dev/null; printf 'fix\n' >> impl.txt; A handoff LC IMPLEMENTED >/dev/null; pass_all self; A handoff LC CODE_DONE >/dev/null
s=$(A summary LC); has "review passed after the fix" "$s" 'REVIEW: pass (attempts 2)'; has "no open finding" "$s" 'FINDINGS: open 0, failing gate records 1'
has "verify" "$s" 'VERIFY: pass (attempts 1)'; has "handoff" "$s" 'DELIVERY: handoff CODE_DONE'
s=$(AGENT_ROLE=independent_qa A summary LC); has "read-only role may summarize" "$s" 'STATUS: '
expect_fail "unknown task" A summary NOPE
echo "oversight: summary passed"

# --- report: location, isolation, byte-identical run state, no source leak --------------------------
before=$(tree_hash .agents/runs/LC); gs=$(git status --porcelain)
out=$(A report LC); path=${out#report: }; dir=$(rdir)
[ "$path" = "$dir/LC.html" ] && [ -f "$path" ] || bad "report path: $path"
case "$path" in "$(pwd)"/*) bad "report inside the repository" ;; esac
[ "$(ls -ld "$dir" | cut -c1-10)" = drwx------ ] || bad "report dir is not mode 700"
[ "$(tree_hash .agents/runs/LC)" = "$before" ] || bad "report changed the run directory"
[ "$(git status --porcelain)" = "$gs" ] || bad "report changed the working tree"
[ -z "$(find . -name 'LC.html' -not -path './.git/*')" ] || bad "a report was written inside the repository"
html=$(cat "$path"); lacks "source content leaked" "$html" SRC_MARKER_4f9c21
has "changed file listed" "$html" '"path":"impl.txt"'; has "files are counts" "$html" '"add":'
data_of "$path" | json_ok || bad "data block is not well-formed JSON"
! command -v node >/dev/null 2>&1 || data_of "$path" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' || bad "node rejects the data block"
[ "$(grep -o '</script' "$path" | wc -l | tr -d ' ')" = "$(grep -o '</script' .agents/skills/oversight-report/assets/report-template.html | wc -l | tr -d ' ')" ] || bad "script tag count changed"
has "an expected role without a record" "$html" '"role":"independent_reviewer","state":"expected_no_record"'
has "recorded role" "$html" '"role":"full_lifecycle","state":"recorded"'
rm -f "$path"; : > "$base/victim"; ln -s "$base/victim" "$path"
expect_fail "report through a symlink target" A report LC
[ -L "$path" ] && [ ! -s "$base/victim" ] || bad "a symlink target was followed"
rm -f "$path"
mkdir inrepo; expect_fail "TMPDIR inside the repository" env TMPDIR="$(pwd)/inrepo" ./scripts/agent.sh report LC
[ -z "$(ls -A inrepo)" ] || bad "report directory created inside the repository"; rmdir inrepo
# report directory: ownership, mode and symlink checks (the name is predictable); data file handling
rm -rf "$dir"; mkdir "$dir"; chmod 777 "$dir"
A report LC >/dev/null || bad "report refused a pre-existing mode 777 directory that we own"
[ "$(ls -ld "$dir" | cut -c1-10)" = drwx------ ] || bad "a pre-existing 777 report directory was not tightened to 700"
[ -z "$(ls -A "$dir" | grep '^\.report\.' || true)" ] || bad "report left a temp file behind"
rm -rf "$dir"; mkdir "$base/elsewhere"; ln -s "$base/elsewhere" "$dir"
expect_fail "symlinked report directory" A report LC
[ -z "$(ls -A "$base/elsewhere")" ] || bad "report wrote through a symlinked directory"
rm -f "$dir"; mkdir -m 700 "$dir"; mkdir -p "$base/idstub"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 4242424; else exec /usr/bin/id "$@"; fi\n' > "$base/idstub/id"; chmod +x "$base/idstub/id"
expect_fail "report directory not owned by the current user" env PATH="$base/idstub:$PATH" ./scripts/agent.sh report LC
[ -z "$(ls -A "$dir")" ] || bad "report wrote into a directory it could not verify as ours"
bs="$base/b\\s"; mkdir -p "$bs"; out=$(TMPDIR=$bs ./scripts/agent.sh report LC) || bad "report failed for a TMPDIR containing a backslash"
bp=$bs/agent-oversight-$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-16)/LC.html
[ "$out" = "report: $bp" ] || bad "printed path mangled: $out"
data_of "$bp" | json_ok || bad "report with a backslash TMPDIR has an empty or broken data block"
mkdir -p "$base/noread"; chmod 000 "$base/noread"
expect_fail "unreadable TMPDIR" env TMPDIR="$base/noread" ./scripts/agent.sh report LC; chmod 755 "$base/noread"
echo "oversight: report location and isolation passed"

# --- retention: bounded prune of old html in this repository's report directory only ---------------
: > "$dir/old.html"; : > "$dir/old.txt"; : > "$dir/new.html"; touch -t 200001010000 "$dir/old.html" "$dir/old.txt"
mkdir -p "$base/tmp/agent-oversight-other"; : > "$base/tmp/agent-oversight-other/old.html"; touch -t 200001010000 "$base/tmp/agent-oversight-other/old.html"
A report LC >/dev/null
[ ! -e "$dir/old.html" ] && [ -e "$dir/old.txt" ] && [ -e "$dir/new.html" ] || bad "retention prune"
[ -e "$base/tmp/agent-oversight-other/old.html" ] || bad "prune reached another directory"
echo "oversight: retention passed"

# --- cleanup deletes the task's report file only; a missing report does not fail cleanup -----------
cp "$path" "$dir/OTHER.html"; A report LC >/dev/null; finish_done; A cleanup LC >/dev/null
[ ! -e "$path" ] && [ ! -e .agents/runs/LC ] && [ -e "$dir/OTHER.html" ] || bad "cleanup removed the wrong files or kept the report"
scaffold standalone false; drive; finish_done
[ ! -e "$(rdir)/LC.html" ] || bad "stale report"; A cleanup LC >/dev/null || bad "cleanup failed without a report"
echo "oversight: cleanup passed"

# --- hostile text (title, criterion, finding, path, command) ----------------------------------------
scaffold standalone false; dir=$(rdir); path=$dir/LC.html
hostile='</script><img src=x onerror=alert(1)> & "q" \ back'
printf '# Task: %s\n\n## Acceptance criteria\n\n- AC-1: %s\n' "$hostile" "$hostile" > .agents/runs/LC/TASK.md
printf '# Verify\n\nVerdict: PASS\n\n## Commands\n\n- `echo %s` | exit=0\n' "$hostile" > .agents/runs/LC/VERIFY.md
sed 's/^  - path: impl_test.txt/  - path: x<b>"y.txt/' .agents/runs/LC/PLAN.md > "$base/plan" && cat "$base/plan" > .agents/runs/LC/PLAN.md; printf 'x\n' > 'x<b>"y.txt'
A report LC >/dev/null; html=$(cat "$path")
lacks "raw markup" "$html" '<img'; lacks "raw script close in data" "$(data_of "$path")" '</script'; lacks "raw ampersand in data" "$(data_of "$path")" '& '
has "escaped markup" "$html" '\u003c/script\u003e\u003cimg'; has "escaped quote and backslash" "$html" '\"q\" \\ back'
data_of "$path" | json_ok || bad "hostile data block is not well-formed JSON"
! command -v node >/dev/null 2>&1 || data_of "$path" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' || bad "node rejects the hostile data block"
[ "$(grep -o '</script' "$path" | wc -l | tr -d ' ')" = 2 ] || bad "hostile text changed the script tags"
echo "oversight: hostile text passed"

# --- events: fail-open, exact schema, role semantics, epoch-seeded seq ------------------------------
mkdir -p "$base/stub"; cat > "$base/stub/curl" <<'EOT'
#!/bin/sh
b=''; mt=0.3
while [ $# -gt 0 ]; do case $1 in --data-binary) b=$2; shift 2 ;; --max-time) mt=$2; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$b" >> "$STUB_LOG"
case "${STUB_MODE:-ok}" in dead) exit 7 ;; slow) sleep "$mt"; exit 28 ;; esac
EOT
chmod +x "$base/stub/curl"; STUB_LOG=$base/ev.log; export STUB_LOG
scaffold standalone false; echo '.agents/runtime/' >> .git/info/exclude
solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup'
export AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/e
PATH="$base/stub:$PATH" A handoff LC IMPLEMENTED >/dev/null
gate_pass_ev() { write_gate_report REVIEW PASS; PATH="$base/stub:$PATH" AGENT_ROLE=independent_reviewer ./scripts/agent.sh gate LC REVIEW pass >/dev/null <<EOT
summary: ran the full verification command set and inspected the whole diff of the current tree
EOT
}
gate_pass_ev
for k in $(grep -o '"[A-Za-z]*":' "$STUB_LOG" | tr -d '":' | sort -u); do case $k in schema|event|runRef|seq|stage|status|gate|attempt|role|topology|findingsOpen|loop|fingerprint|at|providerSession) ;; *) bad "extra event field: $k" ;; esac; done
grep -q '"event":"gate","runRef":"LC","seq":[0-9]*,"stage":"review","status":"passed","gate":"review","attempt":1,"role":"independent_reviewer"' "$STUB_LOG" || bad "gate event schema or role"
! grep -q '"role":"implementation_worker"' "$STUB_LOG" || bad "an event named a role that did not act"
first=$(sed -n '1s/.*"seq":\([0-9]*\).*/\1/p' "$STUB_LOG"); [ "$first" -gt 1000000000 ] || bad "seq not epoch-seeded: $first"
lacks "event carries no prose" "$(cat "$STUB_LOG")" 'inspected the whole diff'
n=$(wc -l < "$STUB_LOG"); t0=$(date +%s)
( STUB_MODE=slow; PATH="$base/stub:$PATH"; gate_pass independent_qa QA >/dev/null ); ( STUB_MODE=dead; PATH="$base/stub:$PATH"; gate_pass independent_verifier VERIFY >/dev/null )
[ "$(( $(date +%s) - t0 ))" -lt 5 ] || bad "a slow or dead receiver delayed the workflow"; [ "$(wc -l < "$STUB_LOG")" -gt "$n" ] || bad "events were not attempted"
d=$base/noevent; mkdir -p "$d"; AGENT_WORKFLOW_EVENTS_URL=http://x/ sh scripts/oversight/event.sh --root "$d" --task LC --event stage --stage plan --status completed --bogus 1
AGENT_WORKFLOW_EVENTS_URL=http://x/ PATH="$base/stub:$PATH" sh scripts/oversight/event.sh --root "$d" --task LC --event stage --stage nope --status completed
[ ! -e "$d/.agents" ] || bad "an invalid event wrote state"
unset AGENT_WORKFLOW_EVENTS_URL
echo "oversight: events passed"

# --- portability: the documented minimum tools only (no go, node, python, jq or curl) ---------------
scaffold standalone false; drive
mkdir -p "$base/bin"; for t in sh awk sed git shasum cp mv rm mkdir mktemp cat tr grep head tail wc sort cut basename dirname ls date find chmod uniq tee diff id; do ln -sf "$(command -v $t)" "$base/bin/$t"; done
for t in go node python3 jq curl; do [ ! -e "$base/bin/$t" ] || bad "$t on the restricted PATH"; done
PATH="$base/bin" ./scripts/agent.sh summary LC | grep -q 'VERIFY: pass' || bad "summary needs a tool outside the minimum platform"
PATH="$base/bin" ./scripts/agent.sh report LC >/dev/null && [ -f "$(rdir)/LC.html" ] || bad "report needs a tool outside the minimum platform"
echo "oversight: restricted PATH passed"

# --- presentation-deletion invariant: the deterministic workflow does not depend on any of it -------
cd "$base"; mkdir del; (cd "$root" && tar cf - --exclude=./.git --exclude=./.agents/runs .) | tar xf - -C del
rm -rf del/scripts/oversight del/.agents/skills del/.claude/skills del/scripts/oversight-test.sh
sed '/^  summary) /d;/^  report) /d' del/scripts/agent.sh > del/scripts/agent.sh.new && mv del/scripts/agent.sh.new del/scripts/agent.sh && chmod +x del/scripts/agent.sh
sh -n del/scripts/agent.sh || bad "agent.sh without the presentation callers does not parse"
sh del/scripts/exec-policy-test.sh >/dev/null || bad "exec-policy tests fail without the presentation layer"
sh del/scripts/lifecycle-test.sh >/dev/null || bad "lifecycle tests fail without the presentation layer"
echo "oversight: presentation deletion passed"
echo 'oversight tests passed'

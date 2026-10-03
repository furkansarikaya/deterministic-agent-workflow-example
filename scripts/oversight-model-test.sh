#!/bin/sh
# Tests for the oversight layer on synthetic run directories (scripts/oversight-fixture.sh):
# the model, its provenance labels and ordering, the report (determinism, read-only,
# escaping, no source content), role and delegation semantics, the workflow-event
# emitter, and a large run. The end-to-end run through agent.sh and the portability
# test (restricted PATH, several awk engines) are in scripts/oversight-test.sh.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
ovs=$root/scripts/oversight
FX_BASE=$(mktemp -d "${TMPDIR:-/tmp}/oversight-model-test.XXXXXX"); export FX_BASE
trap 'rm -rf "$FX_BASE"' EXIT
. "$root/scripts/oversight-fixture.sh"

n=0
bad() { echo "FAIL: $*" >&2; exit 1; }
ok() { n=$((n + 1)); }
eq() { [ "$2" = "$3" ] || bad "$1 (got '$2', want '$3')"; ok; }
has() { printf '%s' "$2" | grep -Fq -- "$3" || bad "$1 (missing: $3)"; ok; }
lacks() { if printf '%s' "$2" | grep -Fq -- "$3"; then bad "$1 (unexpected: $3)"; fi; ok; }
fails() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; fi; ok; }

O() { sh "$ovs/oversight.sh" "$@" --root "$FX_ROOT" --task "$FX_ID"; }
model() { O model; }
# sect NAME: one top-level section of the model JSON
sect() { awk -v k="  \"$1\": " 'index($0, k) == 1 { on = 1; print; next } on && /^  "/ { on = 0; next } on { print }'; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done | shasum -a 256 | cut -d' ' -f1); }

# ---- model: determinism and ordering ---------------------------------------------
fx_complete
m1=$(model); m2=$(model)
eq "same input, identical model bytes" "$m1" "$m2"
eq "criteria are in natural order" "$(printf '%s\n' "$m1" | grep -o '"id": "AC-[0-9]*"' | tr -d '\n')" '"id": "AC-1""id": "AC-2""id": "AC-10"'
eq "gate records ordered by seq" "$(printf '%s\n' "$m1" | sect gateRecords | grep '^      "seq"' | tr -d ' \n')" '"seq":1,"seq":2,"seq":3,"seq":4,'
eq "flow ordered by ledger seq" "$(printf '%s\n' "$m1" | sect flow | grep '^      "seq"' | tr -d ' \n')" '"seq":1,"seq":2,"seq":3,"seq":4,"seq":5,"seq":6,"seq":7,'
has "schema" "$m1" '"schema": "oversight-model/1"'
has "notice" "$m1" 'Not evidence'
# a ledger written out of order is still read in order
fx_complete; printf '%s\n' "$(tail -n 1 "$FX_DIR/LEDGER.log")" "$(sed -n 1,6p "$FX_DIR/LEDGER.log")" > "$FX_DIR/LEDGER.tmp"; mv "$FX_DIR/LEDGER.tmp" "$FX_DIR/LEDGER.log"
eq "out-of-order ledger" "$(model | sect flow | grep '^      "seq"' | tr -d ' \n')" '"seq":1,"seq":2,"seq":3,"seq":4,"seq":5,"seq":6,"seq":7,'

# ---- model: unavailable stays unavailable ------------------------------------------
fx_new; fx_run PLANNED PLANNING; fx_docs "AC-1: x"
m=$(model)
has "no ledger: flow unavailable" "$(printf '%s\n' "$m" | sect unavailable)" '"flow"'
has "no durations: listed" "$(printf '%s\n' "$m" | sect unavailable)" '"durations"'
eq "durations is an empty list" "$(printf '%s\n' "$m" | sect durations | tr -d ' \n')" '"durations":[],'
eq "no ledger: flow is an empty list" "$(printf '%s\n' "$m" | sect flow | tr -d ' \n')" '"flow":[],'
has "max fixes is read from the mode policy" "$(printf '%s\n' "$m" | sect remediation)" '"value": "2"'
has "a failure reason is not invented" "$(printf '%s\n' "$m" | sect outcome | tr -d ' \n')" '"failureReason":{"value":null,"source":"unavailable"}'
has "no PENDING value leaks" "$(printf '%s\n' "$m" | sect fingerprint | tr -d ' \n')" '"codeDonePatchSha256":{"value":null,"source":"unavailable"}'
# severity and category stay unavailable unless the gate record carries them
fx_complete
f=$(model | sect findings | tr -d ' \n')
has "severity not recorded" "$f" '"severity":{"value":null,"source":"unavailable"}'
has "category not recorded" "$f" '"category":{"value":null,"source":"unavailable"}'
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"
fx_gate 1 REVIEW fail impl1 "findings: wrong" "severity: major" "category: correctness" "fix_scope: src/a.go" "fix_instruction: fix it properly now"
f=$(model | sect findings | tr -d ' \n')
has "recorded severity" "$f" '"severity":{"value":"major","source":"recorded"}'
has "recorded category" "$f" '"category":{"value":"correctness","source":"recorded"}'
# a gate record is labelled against the frozen contract, not trusted
sed -i.bak 's/^plan_sha256: .*/plan_sha256: "stale"/' "$FX_DIR/gates/001-REVIEW.yaml"; rm -f "$FX_DIR/gates/001-REVIEW.yaml.bak"
f=$(model)
has "stale record is not bound" "$(printf '%s\n' "$f" | sect gateRecords | tr -d ' \n')" '"boundToCurrentContract":{"value":false,"source":"derived"}'
has "stale finding is superseded" "$(printf '%s\n' "$f" | sect findings | tr -d ' \n')" '"state":"superseded"'

# ---- remediation loops only from evidence --------------------------------------------
fx_complete
m=$(model); rem=$(printf '%s\n' "$m" | sect remediation | tr -d ' \n')
has "one loop" "$rem" '"loop":1,"gate":"REVIEW","failedGateSeq":1,'
has "fix started is recorded in the ledger" "$rem" '"fixStarted":{"value":true,"source":"derived"}'
has "fix returned is recorded in the ledger" "$rem" '"fixReturned":{"value":true,"source":"derived"}'
has "resolved by a later pass" "$rem" '"value":"gate002REVIEWpass","source":"derived"'
has "finding resolved" "$(printf '%s\n' "$m" | sect findings | tr -d ' \n')" '"state":"resolved"'
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"; fx_gate 1 VERIFY pass impl1
m=$(model)
eq "a passing run has no loops" "$(printf '%s\n' "$m" | sect remediation | tr -d ' \n' | cut -c1-30)" '"remediation":{"loops":[],"max'
eq "a passing run has no findings" "$(printf '%s\n' "$m" | sect findings | tr -d ' \n')" '"findings":[],'
# a failing gate with a ledger but no fix events: not started (false), never "unknown"
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"
fx_gate 1 QA fail impl1 "findings: scenario two fails" "fix_scope: src/a.go" "fix_instruction: handle the empty key"
rem=$(model | sect remediation | tr -d ' \n')
has "no fix event: not started" "$rem" '"fixStarted":{"value":false,"source":"derived"}'
has "no fix event: not returned" "$rem" '"fixReturned":{"value":false,"source":"derived"}'
has "an unresolved failure is open" "$(model | sect findings | tr -d ' \n')" '"state":"open"'
# without any ledger the loop's fix facts are unavailable
rm -f "$FX_DIR/LEDGER.log"
rem=$(model | sect remediation | tr -d ' \n')
has "no ledger: fix start unavailable" "$rem" '"fixStarted":{"value":null,"source":"unavailable"}'
has "no ledger: fix return unavailable" "$rem" '"fixReturned":{"value":null,"source":"unavailable"}'
# at termination an open finding says so, and the failure reason comes from the ledger only
fx_new; fx_run IMPLEMENTED FAILED; fx_docs "AC-1: x"
fx_gate 1 QA fail impl1 "findings: scenario two fails" "fix_scope: src/a.go" "fix_instruction: handle the empty key"
fx_ledger terminate IMPLEMENTED FAILED "reason: fix budget exhausted on QA; evidence: gate 001 still failing"
m=$(model)
has "unresolved at termination" "$(printf '%s\n' "$m" | sect findings | tr -d ' \n')" '"state":"unresolved_at_termination"'
has "failure reason" "$(printf '%s\n' "$m" | sect outcome | tr -d ' \n')" '"failureReason":{"value":"fixbudgetexhaustedonQA"'
has "failure evidence" "$(printf '%s\n' "$m" | sect outcome)" '"value": "gate 001 still failing"'

# ---- AC and evidence links only where supported ---------------------------------------
fx_complete
m=$(model); crit=$(printf '%s\n' "$m" | sect criteria | tr -d ' \n')
has "AC-1 files" "$crit" '"id":"AC-1","text":"lookupreturnsthestoredvalue","files":["src/a.go","src/a_test.go"],"qaScenarios":["QA-1","QA-2"],"evidenceRefs":["src/a.go:Lookup"],"qaResult":{"value":"PASS","source":"derived"}'
has "AC-2 has nothing invented" "$crit" '"id":"AC-2","text":"unrelatedrequirement","files":[],"qaScenarios":[],"evidenceRefs":[],"qaResult":{"value":null,"source":"unavailable"},"unavailable":["files","qaScenarios","evidenceRefs"]'
links=$(printf '%s\n' "$m" | sect links)
lacks "no link from AC-2" "$links" '"from": "AC-2"'
lacks "no link from AC-10" "$links" '"from": "AC-10"'
lacks "an unrelated file:symbol is not linked" "$links" 'src/b.go:Other'
has "a stated link exists" "$links" '"kind": "scopes"'
v=$(printf '%s\n' "$m" | sect verification | tr -d ' \n')
has "verifier command with exit" "$v" '"command":"gotest./...","result":{"value":"exit=0","source":"recorded"}'
has "verifier command without exit" "$v" '"command":"freetextwithoutexit","result":{"value":null,"source":"unavailable"}'
# the VERIFY template asks for the relevant output under each command; the parser must tolerate those lines
tpl=$(cat "$root/.agents/templates/VERIFY.md")
has "VERIFY template keeps the parsed command format" "$tpl" '- `<exact command>` | exit=<n>'
has "VERIFY template asks for the relevant output" "$tpl" 'output:'
printf '# V\n\nVerdict: PASS\n\n## Commands\n\n- `go test ./...` | exit=0\n  output: ok pkg 0.4s, 12 passed\n- `go vet ./...` | exit=1\n  output: impl.go:3: unreachable code\n\n## Plan conformance\n\nok\n' > "$FX_DIR/VERIFY.md"
v=$(model | sect verification | tr -d ' \n')
has "a command followed by an output line still parses" "$v" '"command":"gotest./...","result":{"value":"exit=0","source":"recorded"}'
has "the next command still parses" "$v" '"command":"govet./...","result":{"value":"exit=1","source":"recorded"}'
lacks "an output line is not taken for a command" "$v" 'okpkg'

# ---- JSON is valid: control characters, quotes and backslashes are escaped ---------------
fx_complete; fx_docs 'AC-1: back\slash "quoted" & <b>' 'AC-2: tab	inside'
fx_gate 5 REVIEW fail impl9 "findings: ctrl$(printf '\001')char and tab	here" "fix_scope: src/a.go" "fix_instruction: fix it properly now"
m=$(model)
has "backslash escaped" "$m" 'back\\slash \"quoted\"'
has "tab escaped" "$m" 'tab\tinside'
has "control byte escaped" "$m" 'ctrl\u0001char and tab\there'
eq "no raw control byte in the JSON" "$(printf '%s' "$m" | tr -d '\n' | LC_ALL=C tr -d '[:print:]' | wc -c | tr -d ' ')" 0
eq "deterministic with hostile input" "$m" "$(model)"

# ---- report: determinism, read-only, no external reference ---------------------------------
fx_complete
before=$(tree_hash "$FX_DIR")
rep=$FX_ROOT/.agents/runtime/reports/T-1.html
O report >/dev/null; r1=$(shasum -a 256 < "$rep"); O report >/dev/null; r2=$(shasum -a 256 < "$rep")
eq "same input, identical report bytes" "$r1" "$r2"
eq "report generation leaves the run directory byte-identical" "$(tree_hash "$FX_DIR")" "$before"
fails "a report inside .agents/runs/ is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --out "$FX_DIR/REPORT.html"
git -C "$FX_ROOT" init -q >/dev/null 2>&1
git_before=$(shasum -a 256 < "$FX_ROOT/.git/config")
fails "a report over git metadata (.git/config) is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --out "$FX_ROOT/.git/config"
fails "a report inside git metadata (.git/info/x) is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --out "$FX_ROOT/.git/info/x.html"
eq "git metadata is byte-identical after the refusals" "$(shasum -a 256 < "$FX_ROOT/.git/config")" "$git_before"
# a linked worktree whose main repository path contains spaces: the guard must not split the path
wtm="$FX_BASE/wt sp/main repo"; wtl="$FX_BASE/wt sp/linked"
mkdir -p "$wtm" && git -C "$wtm" init -q && git -C "$wtm" -c user.email=a@b -c user.name=x commit -q --allow-empty -m i && git -C "$wtm" worktree add -q "$wtl" -b wtb
cp -R "$FX_ROOT/.agents" "$wtl/"
wt_before=$(shasum -a 256 < "$wtm/.git/config")
fails "a report over the main repository's .git/config (path with spaces, linked worktree) is refused" sh "$ovs/oversight.sh" report --root "$wtl" --task T-1 --out "$wtm/.git/config"
fails "a report inside the main repository's .git/worktrees (path with spaces) is refused" sh "$ovs/oversight.sh" report --root "$wtl" --task T-1 --out "$wtm/.git/worktrees/linked/HEAD"
eq "the main repository's git metadata is byte-identical after the refusals" "$(shasum -a 256 < "$wtm/.git/config")" "$wt_before"
fails "a report inside .agents/runs/ through .. is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --out "$FX_ROOT/.agents/runtime/../runs/T-1/R.html"
[ ! -e "$FX_DIR/REPORT.html" ] && [ ! -e "$FX_DIR/R.html" ] || bad "a refused report was written anyway"; ok
ln -s "$FX_DIR" "$FX_BASE/runs-link"
fails "a report inside .agents/runs/ through a symlink is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --out "$FX_BASE/runs-link/R.html"
fails "an unknown option is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task T-1 --nope
fails "an unknown task is refused" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task NOPE
fails "a task id with a path is refused" sh "$ovs/oversight.sh" model --root "$FX_ROOT" --task ../x
h=$(cat "$rep")
for id in overview flow remediation criteria files findings verification provenance; do has "section $id" "$h" "id=\"$id\""; done
has "provenance statement" "$h" 'This report is not evidence'
eq "four diagrams" "$(printf '%s' "$h" | grep -o '<svg' | wc -l | tr -d ' ')" 4
stripped=$(printf '%s' "$h" | sed 's|xmlns="http://www.w3.org/2000/svg"||g')
for ext in 'http://' 'https://' '<link' '@import' 'src="http'; do lacks "external reference $ext" "$stripped" "$ext"; done
eq "no inline script (report.js removed)" "$(printf '%s' "$h" | grep -o '<script>' | wc -l | tr -d ' ')" 0; [ ! -e "$ovs/report.js" ] || bad "scripts/oversight/report.js still exists"

# ---- report: every dynamic value is escaped ----------------------------------------------------
fx_complete
evil='<script>alert(1)</script>'
fx_docs "AC-1: $evil" 'AC-2: "><img src=x onerror=alert(2)> & '"'"'single'"'"
fx_gate 5 REVIEW fail impl9 "findings: $evil" "fix_scope: src/a.go" "fix_instruction: $evil fix it"
printf '# V\n\n## Commands\n\n- `echo %s` | exit=0\n' "$evil" > "$FX_DIR/VERIFY.md"
fx_ledger amend IMPLEMENTED IMPLEMENTED "$evil"
printf 'src/<img src=x onerror=alert(3)>.go|h\nsrc/a&b"c.go|h\n' > "$FX_DIR/gates/005-REVIEW.manifest"
O report >/dev/null; h=$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")
lacks "unescaped script" "$h" "$evil"
lacks "unescaped script close" "$h" 'alert(1)</script>'
lacks "unescaped img in a title" "$h" '<img src=x'
lacks "unescaped img in a path" "$h" 'onerror=alert(3)>'
has "escaped script" "$h" '&lt;script&gt;alert(1)&lt;/script&gt;'
has "escaped quote and ampersand" "$h" '&quot;&gt;&lt;img src=x onerror=alert(2)&gt; &amp; &#39;single&#39;'
has "escaped path" "$h" 'src/&lt;img src=x onerror=alert(3)&gt;.go'
has "escaped path with quote" "$h" 'src/a&amp;b&quot;c.go'
eq "still no inline script" "$(printf '%s' "$h" | grep -o '<script>' | wc -l | tr -d ' ')" 0
# a hostile run id cannot reach the page: the id is validated before anything is read
fails "hostile task id" sh "$ovs/oversight.sh" report --root "$FX_ROOT" --task '<script>'

# ---- no source content in the model or the report; the report directory is ignored ----------------
fx_complete
mark=SECRET_SOURCE_MARKER_9f3a
mkdir -p "$FX_ROOT/src"; printf 'package a\n// %s\n' "$mark" > "$FX_ROOT/src/a.go"; printf 'package a\n// %s\n' "$mark" > "$FX_ROOT/src/a_test.go"
cp "$root/.gitignore" "$FX_ROOT/.gitignore"
G() { git -C "$FX_ROOT" -c user.name=x -c user.email=x@example.invalid "$@"; }
G init -q -b main; G add src/a.go .gitignore; G commit -qm base
base=$(G rev-parse HEAD)
printf 'package a\n// %s\nfunc A() {}\n' "$mark" > "$FX_ROOT/src/a.go"
printf 'a\000b\n' > "$FX_ROOT/blob.bin"
printf 'src/a.go|h\nsrc/a_test.go|h\nblob.bin|h\n' > "$FX_DIR/gates/004-VERIFY.manifest"
sed "s/abc123/$base/" "$FX_DIR/RUN.yaml" > "$FX_DIR/RUN.tmp"; mv "$FX_DIR/RUN.tmp" "$FX_DIR/RUN.yaml"
status_before=$(G status --porcelain | shasum -a 256)
m=$(model); ds=$(printf '%s\n' "$m" | sect diffstat | tr -d ' \n')
eq "diffstat: tracked +1, untracked test file +2, binary skipped" "$ds" '"diffstat":{"files":3,"added":{"value":3,"source":"derived"},"deleted":{"value":0,"source":"derived"}},'
has "a binary file keeps unavailable counts" "$(printf '%s\n' "$m" | sect files | tr -d ' \n')" '"path":"blob.bin","status":"changed","source":"recorded","added":{"value":null,"source":"unavailable"}'
O report >/dev/null
lacks "source content in the model" "$m" "$mark"
lacks "source content in the report" "$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")" "$mark"
G check-ignore -q .agents/runtime/reports/T-1.html || bad "the report directory is not git-ignored"; ok
eq "report generation does not dirty the working tree" "$(G status --porcelain | shasum -a 256)" "$status_before"
# portability: this fixture (git diffstat, an untracked file, a binary file) under a PATH of PORTABLE_TOOLS only,
# once per awk engine found, gives byte-identical model, summary and report
ref_m=$m; ref_s=$(O summary | grep -v '^report:'); ref_h=$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html"); k=0
for eng in $(awk_engines); do
  k=$((k + 1)); restricted_path "$FX_BASE/rp$k" "$eng"
  rm -f "$FX_ROOT/.agents/runtime/reports/T-1.html"
  P() { env PATH="$FX_BASE/rp$k" /bin/sh "$ovs/oversight.sh" "$@" --root "$FX_ROOT" --task T-1; }
  eq "restricted PATH, awk $eng: model" "$(P model)" "$ref_m"
  eq "restricted PATH, awk $eng: summary" "$(P summary | grep -v '^report:')" "$ref_s"
  P report >/dev/null
  eq "restricted PATH, awk $eng: report" "$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")" "$ref_h"
done
# without a usable base commit the diffstat is unavailable, never guessed
sed "s/$base/0000000000000000000000000000000000000000/" "$FX_DIR/RUN.yaml" > "$FX_DIR/RUN.tmp"; mv "$FX_DIR/RUN.tmp" "$FX_DIR/RUN.yaml"
m=$(model)
has "bad base: diffstat unavailable" "$(printf '%s\n' "$m" | sect diffstat | tr -d ' \n')" '"added":{"value":null,"source":"unavailable"}'
has "bad base: listed unavailable" "$(printf '%s\n' "$m" | sect unavailable)" '"diffstat"'

# ---- the CLI summary derives from the same model ----------------------------------------------------
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"
fx_gate 1 QA fail impl1 "findings: scenario two fails" "fix_scope: src/a.go" "fix_instruction: handle the empty key"
m=$(model); s=$(O summary)
open=$(printf '%s\n' "$m" | sect lifecycle | tr -d ' \n' | sed -n 's/.*"stage":"qa","status":"failed","source":"derived","gate":true,"attempts":1,"findingsOpen":\([0-9]*\).*/\1/p')
eq "open findings: model" "$open" 1
has "open findings: summary shows the same value" "$s" "gate qa     FAIL    attempts=1 open_findings=$open"
stages=$(printf '%s\n' "$m" | sect lifecycle | grep '"stage":' | sed 's/.*"stage": "\(.*\)",/\1/' | tr '\n' ' ')
has "summary lists the model's stages" "$s" "flow: discover[ok] > evidence[ok] > plan[ok] > implement[ok] > review[-] > qa[FAIL] > verify[-] > code_done[-] > knowledge[-] > done[-]"
eq "stage names in the model" "$stages" 'discover evidence plan implement review qa verify code_done knowledge done '
has "loops: model and summary agree" "$s" "remediation: 1 loops, 1 failing gates, max fixes 2"
lacks "no report path before a report exists" "$s" "report:"
O report >/dev/null
has "report path once generated" "$(O summary)" "report: .agents/runtime/reports/T-1.html"
has "summary header" "$s" "T-1  COMPLEX  IMPLEMENTED  topology=standalone"
has "unavailable items are listed" "$s" "unavailable: "

# ---- role and topology semantics ----------------------------------------------------------------------
# expected is derived from the pipeline or topology and is not proof the role ran
role_obj() { printf '%s\n' "$1" | sect roles | tr -d ' \n' | sed 's/},{/}\
{/g' | grep "\"role\":\"$2\""; }
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"
fx_ledger classify PLANNED PLANNED "COMPLEX review=yes"
fx_gate 1 REVIEW fail impl1 "findings: lookup is wrong for an empty key" "fix_scope: src/a.go" "fix_instruction: return the default for an empty key"
m=$(model); s=$(O summary); O report >/dev/null; h=$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")
has "reviewer: recorded" "$(role_obj "$m" independent_reviewer)" '"expected":true,"expectedBy":"pipeline","records":1,"activity":["gateREVIEWfail"],"executed":{"value":true,"source":"recorded"},"status":"recorded","source":"recorded"'
has "qa: expected, no record" "$(role_obj "$m" independent_qa)" '"expected":true,"expectedBy":"pipeline","records":0,"activity":[],"executed":{"value":null,"source":"unavailable"},"status":"expected_no_record","source":"derived"'
has "verifier: expected, no record" "$(role_obj "$m" independent_verifier)" '"status":"expected_no_record"'
has "summary: reviewer recorded" "$s" "independent_reviewer[recorded 1]"
has "summary: qa expected only" "$s" "independent_qa[expected · no record]"
has "summary: verifier expected only" "$s" "independent_verifier[expected · no record]"
lacks "summary: qa never shown as run" "$s" "independent_qa[recorded"
lacks "summary: verifier never shown as run" "$s" "independent_verifier[recorded"
has "html: expected role says so" "$h" 'expected · no record'
qa_node=$(printf '%s' "$h" | sed 's|</g>|</g>\
|g' | grep '>independent_qa</text>')
has "svg: the qa node is the dashed expected style" "$qa_node" '<g class="nd na">'
has "svg: the qa node says expected" "$qa_node" 'expected · no record'
lacks "svg: the qa node does not claim records" "$qa_node" 'records (recorded)'
rv_node=$(printf '%s' "$h" | sed 's|</g>|</g>\
|g' | grep '>independent_reviewer</text>')
has "svg: the reviewer node is the recorded style" "$rv_node" '<g class="nd ok">'
has "svg: the reviewer node counts its record" "$rv_node" '1 records (recorded)'
# no ledger and no gate record at all: even the orchestrator is only expected
fx_new; fx_run PLANNED PLANNING; fx_docs "AC-1: x"
m=$(model)
has "orchestrator with no record" "$(role_obj "$m" full_lifecycle)" '"expectedBy":"lifecycle","records":0,"activity":[],"executed":{"value":null,"source":"unavailable"},"status":"expected_no_record","source":"derived"'
has "summary: orchestrator expected only" "$(O summary)" "full_lifecycle[expected · no record]"
# a role that left a record but was not expected is shown as recorded and not expected
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: x"; fx_ledger classify PLANNED PLANNED x explorer
has "unexpected recorded role" "$(role_obj "$(model)" explorer)" '"expected":false,"expectedBy":"","records":1,'
# delegation: orchestrated topology expects a worker; the edge is drawn solid only with the worker's records
fx_new; fx_run IMPLEMENTED PLANNING orchestrated; fx_docs "AC-1: x"; fx_ledger classify PLANNED PLANNED x
m=$(model); O report >/dev/null; h=$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")
has "worker expected by topology" "$(role_obj "$m" implementation_worker)" '"expected":true,"expectedBy":"topology","records":0,'
has "worker: expected, no record" "$(role_obj "$m" implementation_worker)" '"status":"expected_no_record"'
has "delegation is only expected" "$(printf '%s\n' "$m" | sect delegations | tr -d ' \n')" '"from":"full_lifecycle","to":"implementation_worker","via":"scripts/worker-run.sh","status":"expected","source":"derived"'
has "svg: the edge is labelled expected" "$h" '>expected</text>'
lacks "svg: no recorded delegation label" "$h" '>delegates</text>'
has "svg: the expected edge is dashed" "$h" 'class="ed dash" marker-end="url(#ro)"'
has "summary: worker expected only" "$(O summary)" "implementation_worker[expected · no record]"
fx_evidence RED 1 fail src/a_test.go implementation_worker
m=$(model); O report >/dev/null; h=$(cat "$FX_ROOT/.agents/runtime/reports/T-1.html")
has "worker evidence makes the delegation recorded" "$(printf '%s\n' "$m" | sect delegations | tr -d ' \n')" '"status":"recorded","source":"recorded"'
has "worker: recorded" "$(role_obj "$m" implementation_worker)" '"records":1,"activity":["evidenceRED"],"executed":{"value":true,"source":"recorded"},"status":"recorded"'
has "svg: the recorded delegation label" "$h" '>delegates</text>'
lacks "svg: no expected label left" "$h" '>expected</text>'
has "summary: worker recorded" "$(O summary)" "implementation_worker[recorded 1]"
# standalone topology has no delegation edge at all
fx_new; fx_run IMPLEMENTED PLANNING standalone; fx_docs "AC-1: x"
eq "standalone: no delegation" "$(model | sect delegations | tr -d ' \n')" '"delegations":[],'
fx_run IMPLEMENTED PLANNING PENDING
has "topology unavailable is listed" "$(model | sect unavailable)" '"topology"'

# ---- workflow events -----------------------------------------------------------------------------------------
stub_curl() { # DIR MODE
  mkdir -p "$1"
  cat > "$1/curl" <<EOT
#!/bin/sh
body=''; mt=''; all=''
while [ \$# -gt 0 ]; do
  case "\$1" in --data-binary) body=\$2; shift 2 ;; --max-time) mt=\$2; all="\$all \$1 \$2"; shift 2 ;; *) all="\$all \$1"; shift ;; esac
done
case "$2" in nofrac) case "\$all" in *"--max-time 0."*|*"--connect-timeout 0."*) exit 2 ;; esac ;; esac
printf '%s\\n' "\$body" >> "\${STUB_CURL_LOG}.bodies"
printf '%s\\n' "\$all" >> "\${STUB_CURL_LOG}.args"
case "$2" in ok|nofrac) exit 0 ;; dead) exit 7 ;; slow) sleep "\${mt:-1}"; exit 28 ;; esac
EOT
  chmod +x "$1/curl"
}
EV=$FX_BASE/events; mkdir -p "$EV"
ev_run() { # MODE args... : run event.sh with a stub curl; echoes nothing, sets nothing
  em=$1; shift; stub_curl "$EV/stub-$em" "$em"
  STUB_CURL_LOG=$EV/log PATH=$EV/stub-$em:$PATH AGENT_WORKFLOW_EVENTS_URL=${EV_URL-http://127.0.0.1:9/events} sh "$ovs/event.sh" --root "$EV/root" "$@"
}
bodies() { cat "$EV/log.bodies" 2>/dev/null || true; }
reset_ev() { rm -rf "$EV/log.bodies" "$EV/log.args" "$EV/root"; mkdir -p "$EV/root"; }
reset_ev; fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
out=$(ev_run ok --task T-1 --event gate --stage review --status failed --gate review --attempt 2 --role independent_reviewer --topology standalone --findings-open 1 --loop 1 --fingerprint "$fp" --report-available false 2>&1); rc=$?
eq "emit exits 0" "$rc" 0
eq "emit is silent" "$out" ""
b=$(bodies)
eq "one event, schema order, every optional field" "$(printf '%s' "$b" | sed 's/"at":"[^"]*"/"at":"T"/; s/"seq":[0-9]*/"seq":N/')" '{"schema":"workflow-event/1","event":"gate","runRef":"T-1","seq":N,"stage":"review","status":"failed","gate":"review","attempt":2,"role":"independent_reviewer","topology":"standalone","findingsOpen":1,"loop":1,"fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reportAvailable":false,"at":"T"}'
has "at is an ISO time" "$b" '"at":"20'
eq "at has the schema format" "$(printf '%s' "$b" | sed -n 's/.*"at":"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\.[0-9]\{3\}Z\)".*/ok/p')" ok
ev_run ok --task T-1 --event stage --stage plan --status completed
ev_run ok --task T-2 --event stage --stage plan --status completed --attempt -1 --loop -1 --findings-open -1
lines=$(bodies)
sq() { printf '%s\n' "$lines" | sed -n 's/.*"runRef":"'"$1"'","seq":\([0-9]*\),.*/\1/p'; }
s1=$(sq T-1 | sed -n 1p); s2=$(sq T-1 | sed -n 2p); s3=$(sq T-2 | sed -n 1p)
[ "$s1" -ge 1700000000 ] || bad "a missing seq counter must be seeded from the epoch, not restart at 1 (got $s1)"; ok
[ "$s3" -ge 1700000000 ] || bad "a missing seq counter of another run must be seeded from the epoch (got $s3)"; ok
eq "seq is monotonic per run (+1 after the seed)" "$((s2 - s1))" 1
eq "a minimal event has no extra field" "$(printf '%s\n' "$lines" | sed -n 2p | sed 's/"at":"[^"]*"/"at":"T"/; s/"seq":[0-9]*/"seq":N/')" '{"schema":"workflow-event/1","event":"stage","runRef":"T-1","seq":N,"stage":"plan","status":"completed","at":"T"}'
eq "a negative number omits the field" "$(printf '%s\n' "$lines" | sed -n 3p | sed 's/"at":"[^"]*"/"at":"T"/; s/"seq":[0-9]*/"seq":N/')" '{"schema":"workflow-event/1","event":"stage","runRef":"T-2","seq":N,"stage":"plan","status":"completed","at":"T"}'
[ -f "$EV/root/.agents/runtime/events/T-1.seq" ] || bad "seq is kept in the ignored runtime directory"; ok
# a deleted counter (or another checkout with the same task id) never reuses small seq values
rm -f "$EV/root/.agents/runtime/events/T-1.seq"
ev_run ok --task T-1 --event stage --stage plan --status completed
ev_run ok --task T-1 --event stage --stage plan --status completed
lines=$(bodies); s4=$(sq T-1 | tail -n 2 | sed -n 1p); s5=$(sq T-1 | tail -n 1)
[ "$s4" -ge 1700000000 ] || bad "a recreated seq counter restarted with a small value (got $s4)"; ok
eq "seq stays monotonic after a reseed" "$((s5 - s4))" 1
# prose, paths and titles are rejected by validation and never sent
before=$(bodies | wc -l | tr -d ' ')
ev_run ok --task T-1 --event gate --stage review --status failed --role 'please implement the <b>auth</b> task'
ev_run ok --task '../etc/passwd' --event gate --stage review --status failed
ev_run ok --task T-1 --event gate --stage 'my private stage title' --status failed
ev_run ok --task T-1 --event gate --stage review --status failed --fingerprint 'not a hash'
ev_run ok --task T-1 --event gate --stage review --status failed --gate /home/me/src
ev_run ok --task T-1 --event gate --stage review --status failed --attempt two
ev_run ok --task T-1 --event gate --stage review --status failed --nope x
eq "invalid input never reaches the receiver" "$(bodies | wc -l | tr -d ' ')" "$before"
# provider session needs both a known provider and an id
reset_ev
(export AGENT_SESSION_PROVIDER=codex; ev_run ok --task T-1 --event stage --stage plan --status completed)
(export AGENT_SESSION_PROVIDER=other AGENT_SESSION_ID=s1; ev_run ok --task T-1 --event stage --stage plan --status completed)
(export AGENT_SESSION_PROVIDER=claude AGENT_SESSION_ID='bad id'; ev_run ok --task T-1 --event stage --stage plan --status completed)
(export AGENT_SESSION_PROVIDER=claude AGENT_SESSION_ID=sess-9; ev_run ok --task T-1 --event stage --stage plan --status completed)
lacks "no provider session without an id" "$(bodies | sed -n 1p)" providerSession
lacks "no provider session for an unknown provider" "$(bodies | sed -n 2p)" providerSession
lacks "no provider session for a bad id" "$(bodies | sed -n 3p)" providerSession
has "provider session as given" "$(bodies | sed -n 4p)" '"providerSession":{"provider":"claude","sessionId":"sess-9"}'
# fail-open: nothing configured, malformed URLs, no curl, dead receiver, slow receiver
reset_ev
for u in "" "not a url" "ftp://x/y" "file:///etc/passwd" "http://has space/x"; do
  (EV_URL=$u; ev_run ok --task T-1 --event stage --stage plan --status completed) >/dev/null 2>&1 || bad "emit failed for URL '$u'"
done
eq "no call for an unset or malformed URL" "$(bodies | wc -l | tr -d ' ')" 0
[ ! -e "$EV/root/.agents/runtime/events" ] || bad "an unconfigured emit wrote files"; ok
mkdir -p "$EV/nocurl"; for t in sh date mkdir cat; do ln -sf "$(command -v $t)" "$EV/nocurl/$t"; done
out=$(PATH=$EV/nocurl AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/e /bin/sh "$ovs/event.sh" --root "$EV/root" --task T-1 --event stage --stage plan --status completed 2>&1); rc=$?
eq "no curl: exit 0" "$rc" 0
eq "no curl: silent" "$out" ""
[ ! -e "$EV/root/.agents/runtime/events" ] || bad "no curl: files were written"; ok
out=$(ev_run dead --task T-1 --event stage --stage plan --status completed 2>&1); rc=$?
eq "dead receiver: exit 0" "$rc" 0
eq "dead receiver: silent" "$out" ""
reset_ev
t0=$(date +%s)
out=$(ev_run slow --task T-1 --event stage --stage plan --status completed 2>&1); rc=$?
t1=$(date +%s)
eq "slow receiver: exit 0" "$rc" 0
eq "slow receiver: silent" "$out" ""
[ $((t1 - t0)) -le 1 ] || bad "slow receiver blocked for $((t1 - t0)) s (the bound is 0.3 s)"; ok
eq "slow receiver: exactly one attempt, no retry" "$(wc -l < "$EV/log.bodies" | tr -d ' ')" 1
has "bounded by --max-time 0.3" "$(cat "$EV/log.args")" "--max-time 0.3"
has "connect bounded by 0.2" "$(cat "$EV/log.args")" "--connect-timeout 0.2"
has "no retry flag" "$(cat "$EV/log.args")" "--retry 0"
has "silent flags" "$(cat "$EV/log.args")" "-s -o /dev/null"
# a curl that rejects fractional timeouts: silent fallback to whole seconds, still exactly one delivered event
reset_ev
out=$(ev_run nofrac --task T-1 --event stage --stage plan --status completed 2>&1); rc=$?
eq "no fractional timeouts: exit 0" "$rc" 0
eq "no fractional timeouts: silent" "$out" ""
eq "no fractional timeouts: the event is delivered once" "$(wc -l < "$EV/log.bodies" | tr -d ' ')" 1
lacks "no fractional timeouts: the fallback uses whole seconds" "$(cat "$EV/log.args")" "--max-time 0."
has "no fractional timeouts: the fallback is still bounded" "$(cat "$EV/log.args")" "--max-time 1"

# ---- a large run renders in reasonable time -------------------------------------------------------------------------
fx_new; fx_run IMPLEMENTED PLANNING; fx_docs "AC-1: lookup"
i=0
{ printf -- '---\nscope:\n'; while [ $i -lt 500 ]; do printf '  - path: pkg/file%03d.go\n    criteria: [AC-1]\n' "$i"; i=$((i + 1)); done; printf -- '---\n'; } > "$FX_DIR/PLAN.md"
i=1
while [ $i -le 200 ]; do
  case $((i % 3)) in 0) g=REVIEW ;; 1) g=QA ;; *) g=VERIFY ;; esac
  fx_gate "$i" "$g" fail "p$i" "findings: finding number $i needs a fix" "fix_scope: pkg/file001.go" "fix_instruction: apply the fix for it"
  if [ $i -le 10 ]; then fx_ledger handoff:IMPLEMENTING IMPLEMENTED IMPLEMENTING ""; fx_ledger handoff:IMPLEMENTED IMPLEMENTING IMPLEMENTED ""; fi
  i=$((i + 1))
done
i=0; while [ $i -lt 500 ]; do printf 'pkg/file%03d.go|h%d\n' "$i" "$i"; i=$((i + 1)); done > "$FX_DIR/gates/200-VERIFY.manifest"
t0=$(date +%s)
O report >/dev/null; sm=$(O summary); mj=$(model)
t1=$(date +%s)
big=$FX_ROOT/.agents/runtime/reports/T-1.html
has "large run: 500 files" "$sm" "files: 500 changed, 0 planned"
has "large run: 200 loops" "$sm" "remediation: 200 loops"
eq "large run: 200 findings in the model" "$(printf '%s\n' "$mj" | sect findings | grep -c '^      "id": "F-')" 200
[ "$(wc -c < "$big")" -le 1500000 ] || bad "large report is $(wc -c < "$big") bytes"; ok
eq "large run: four diagrams" "$(grep -o '<svg' "$big" | wc -l | tr -d ' ')" 4
has "large run: the remediation diagram is capped" "$(cat "$big")" '176 more loops are in the table.'
[ $((t1 - t0)) -le 15 ] || bad "large run took $((t1 - t0)) s"; ok
echo "oversight: large run (500 files, 200 findings, 200 loops): report + summary + model in $((t1 - t0)) s (clock resolution 1 s)"

echo "oversight model tests passed ($n assertions)"

#!/bin/sh
# End-to-end tests for the oversight layer: `agent.sh summary`, `report` and
# `oversight-model` over a real run driven through the real lifecycle, plus the
# workflow-event emission points (through a stub curl on PATH). The model builder,
# renderer, event emitter and portability have their own tests in
# scripts/oversight-model-test.sh.
#
# OVS_SRC=<dir>   take agent.sh and friends from another checkout (used to measure a baseline)
# OVS_MODE=<name> run one scenario: projection isolation escape gate_fields events event_role report_out portable
# OVS_EXTRA_AWKS="/path/gawk /path/mawk" adds awk engines to the portability scenario
# OVS_MODE=measure print byte sizes of one gate record and one completion report
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
src=${OVS_SRC:-$root}
mode=${OVS_MODE:-all}
base=$(mktemp -d "${TMPDIR:-/tmp}/oversight-test.XXXXXX")
trap 'rm -rf "$base"' EXIT
n_fx=0

. "$root/scripts/oversight-fixture.sh"
A() { ./scripts/agent.sh "$@"; }
AS() { r=$1; shift; AGENT_ROLE=$r ./scripts/agent.sh "$@"; }
expect_fail() { d=$1; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d" >&2; exit 1; fi; }
must_have() { printf '%s' "$2" | grep -Fq -- "$3" || { echo "FAIL: $1 (missing: $3)" >&2; printf '%s\n' "$2" | head -30 >&2; exit 1; }; }
must_lack() { if printf '%s' "$2" | grep -Fq -- "$3"; then echo "FAIL: $1 (unexpected: $3)" >&2; exit 1; fi; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done | shasum -a 256 | cut -d' ' -f1); }

# stub_curl DIR MODE: a curl on PATH that records each request in $STUB_CURL_LOG.bodies and
# .args instead of touching the network. MODE: ok (exit 0), dead (exit 7), slow (obeys --max-time, exit 28).
stub_curl() {
  mkdir -p "$1"
  cat > "$1/curl" <<EOT
#!/bin/sh
body=''; mt=''; all=''
while [ \$# -gt 0 ]; do
  case "\$1" in --data-binary) body=\$2; shift 2 ;; --max-time) mt=\$2; all="\$all \$1 \$2"; shift 2 ;; *) all="\$all \$1"; shift ;; esac
done
printf '%s\\n' "\$body" >> "\${STUB_CURL_LOG:-/dev/null}.bodies"
printf '%s\\n' "\$all" >> "\${STUB_CURL_LOG:-/dev/null}.args"
case "$2" in ok) exit 0 ;; dead) exit 7 ;; slow) sleep "\${mt:-1}"; exit 28 ;; esac
EOT
  chmod +x "$1/curl"
}

scaffold() { # [ac-text]  — a standalone COMPLEX run at IMPLEMENTING, cwd inside the fixture
  n_fx=$((n_fx + 1)); fx=$base/fx$n_fx
  mkdir -p "$fx/.agents/runs/LC" "$fx/.agents/modes" "$fx/.agents/task-integrations" "$fx/scripts" "$fx/tasks"
  cp "$src/scripts/agent.sh" "$src/scripts/worker-run.sh" "$src/scripts/exec-policy.sh" "$fx/scripts/"
  if [ -d "$src/scripts/oversight" ]; then mkdir -p "$fx/scripts/oversight"; cp "$src/scripts/oversight/"* "$fx/scripts/oversight/"; fi
  cp "$src/.agents/config.yaml" "$src/.agents/ENGINEERING.md" "$src/.agents/VERIFICATION.md" "$fx/.agents/"
  cp "$src/.agents/task-integrations/markdown.sh" "$fx/.agents/task-integrations/"; chmod +x "$fx/.agents/task-integrations/markdown.sh"
  cp "$src/.agents/modes/"*.yaml "$fx/.agents/modes/"
  cp "$root/.gitignore" "$fx/.gitignore"
  printf 'LC\n' > "$fx/.agents/ACTIVE_RUN"
  printf '# Task: LC\n\n## Acceptance criteria\n\n- AC-1: %s\n- AC-2: a requirement the plan does not map\n' "${1:-lookup returns the stored value}" > "$fx/.agents/runs/LC/TASK.md"
  printf '# Evidence\n\nAC-1 lives in `impl.txt:lookup`.\n' > "$fx/.agents/runs/LC/EVIDENCE.md"
  printf '# QA plan\n\n- QA-1 (AC-1): lookup returns the stored value\n- QA-2 (AC-1): an empty key returns the default\n' > "$fx/.agents/runs/LC/QA_PLAN.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '---' '# Plan' '' '## Architecture' 'one storage map' > "$fx/.agents/runs/LC/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' '  path: tasks/LC.md' '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' '  topology: standalone' \
    'pipeline:' '  classification: PENDING' '  review: PENDING' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  qa_plan_sha256: PENDING' '  policy_sha256: PENDING' '  pipeline: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    'lifecycle_gates:' '  required: true' > "$fx/.agents/runs/LC/RUN.yaml"
  cd "$fx"
  git init -q -b main; git config user.email oversight@example.invalid; git config user.name fixture
  printf '.agents/runs/\n' >> .git/info/exclude
  [ -z "${OVS_IGNORE_TOOL:-}" ] || printf 'scripts/oversight/\n' >> .git/info/exclude   # lets a scenario break the tool without touching tracked files
  : > impl.txt; : > impl_test.txt; printf '# LC task\n' > tasks/LC.md
  git add -- .gitignore .agents scripts tasks impl.txt impl_test.txt; git commit -qm baseline
  A classify LC COMPLEX >/dev/null; A baseline LC >/dev/null
  A freeze LC >/dev/null; A handoff LC IMPLEMENTING >/dev/null
}

solo() { # phase result file line — standalone: full_lifecycle implements and records its own evidence
  printf '%s\n' "$4" >> "$3"
  e_ef=''; [ "$1" = RED ] && e_ef='expected_failure: TestLookup fails because lookup is not implemented in impl.txt yet'
  printf 'command: go test ./...\ntarget: %s\n%s\n' "${5:-impl.txt,impl_test.txt}" "$e_ef" | A worker-evidence LC "$1" "$2" >/dev/null
}
reports() { # verdict — QA and VERIFY reports in the structured forms the oversight model reads
  printf '# Review\n\nVerdict: %s\n' "$1" > .agents/runs/LC/REVIEW.md
  printf '# QA report\n\nVerdict: %s\n\n- QA-1: %s — stored value returned\n- QA-2: %s — default returned\n' "$1" "$1" "$1" > .agents/runs/LC/QA_REPORT.md
  printf '# Verification\n\nVerdict: %s\n\n## Commands\n\n- `go test ./...` | exit=0\n- `go vet ./...` | exit=0\n\n## Plan conformance\n\nok\n' "$1" > .agents/runs/LC/VERIFY.md
}
gate_pass() {
  reports PASS
  printf 'summary: ran the full verification command set and inspected the whole diff of the current tree\n' | AS "$1" gate LC "$2" pass
}
gate_fail() { # role gate
  reports FAIL
  AS "$1" gate LC "$2" fail <<'EOG'
summary: ran the full verification command set and inspected the whole diff of the current tree
findings: lookup in impl.txt returns the wrong value for an empty key in the reviewed tree
severity: major
category: correctness
fix_scope: impl.txt
fix_instruction: make lookup return the documented default for an empty key and cover it with a test
EOG
}
write_report() {
  printf '%s\n' '# Completion Report: LC' '' '## Implementation Summary' 'impl.txt and impl_test.txt changed.' '' '## TDD Evidence' 'RED then GREEN recorded.' '' \
    '## Verification' 'All gates passed.' '' '## Review Result' 'Approved after one fix.' '' '## QA Result' 'Every frozen QA scenario passed.' '' '## Known Limitations / Follow-up' 'None.' '' '## Amendments' 'None.' > .agents/runs/LC/COMPLETION_REPORT.md
}

# One full lifecycle with one failed REVIEW gate and one bounded fix.
drive_to_review_fail() {
  solo RED fail impl_test.txt 'test: lookup returns the stored value'
  solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail independent_reviewer REVIEW >/dev/null
}
drive_fix_and_pass() {
  A handoff LC IMPLEMENTING >/dev/null
  solo FIX pass impl.txt 'impl: default for an empty key' impl.txt
  A handoff LC IMPLEMENTED >/dev/null
  gate_pass independent_reviewer REVIEW >/dev/null; gate_pass independent_qa QA >/dev/null; gate_pass independent_verifier VERIFY >/dev/null
  A handoff LC CODE_DONE >/dev/null
}
drive_to_done() {
  A knowledge-done LC not_applicable >/dev/null; write_report
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
}

scenario_projection() {
  scaffold
  before=$(A summary LC); must_lack "report path before generation" "$before" "report:"
  drive_to_review_fail
  # summary and model come from the same projection: the open finding is counted in both
  s=$(A summary LC); mdl=$(A oversight-model LC)
  must_have "summary header" "$s" "LC  COMPLEX  IMPLEMENTED  topology=standalone"
  must_have "summary open findings" "$s" "gate review FAIL    attempts=1 open_findings=1"
  must_have "summary remediation" "$s" "remediation: 1 loops"
  # a role the pipeline expects is not shown as having run unless it left records
  must_have "reviewer left a record" "$s" "independent_reviewer[recorded 1]"
  must_have "qa is only expected" "$s" "independent_qa[expected · no record]"
  must_have "verifier is only expected" "$s" "independent_verifier[expected · no record]"
  must_lack "qa shown as run" "$s" "independent_qa[recorded"
  [ "$(printf '%s\n' "$mdl" | grep -c '"state": "open"')" = 1 ] || { echo "FAIL: model and summary disagree on open findings" >&2; exit 1; }
  must_have "recorded severity" "$mdl" '"severity": {'
  must_have "recorded severity value" "$mdl" '"value": "major"'
  # a report never changes run state, evidence, plan, source or tests
  rh=$(tree_hash .agents/runs/LC); sh=$(git status --porcelain | shasum -a 256)
  A report LC >/dev/null; r1=$(shasum -a 256 < .agents/runtime/reports/LC.html)
  A report LC >/dev/null; r2=$(shasum -a 256 < .agents/runtime/reports/LC.html)
  [ "$r1" = "$r2" ] || { echo "FAIL: same run state produced different report bytes" >&2; exit 1; }
  [ "$rh" = "$(tree_hash .agents/runs/LC)" ] || { echo "FAIL: report generation changed the run directory" >&2; exit 1; }
  [ "$sh" = "$(git status --porcelain | shasum -a 256)" ] || { echo "FAIL: report generation dirtied the working tree" >&2; exit 1; }
  git check-ignore -q .agents/runtime/reports/LC.html || { echo "FAIL: report directory is not git-ignored" >&2; exit 1; }
  must_have "summary names the generated report" "$(A summary LC)" "report: .agents/runtime/reports/LC.html"
  h=$(cat .agents/runtime/reports/LC.html)
  for k in 'id="overview"' 'id="flow"' 'id="remediation"' 'id="criteria"' 'id="files"' 'id="findings"' 'id="verification"' 'id="provenance"' 'This report is not evidence'; do must_have "report section" "$h" "$k"; done
  must_have "report finding" "$h" "wrong value for an empty key"
  must_lack "network reference" "$h" "https://"
  # the lifecycle continues untouched, and the report works at every later stage
  drive_fix_and_pass
  A report LC >/dev/null; must_have "code done summary" "$(A summary LC)" "gate verify ok"
  drive_to_done
  A report LC >/dev/null; A validate LC >/dev/null; A delivery-check LC >/dev/null; A verify-gates LC >/dev/null
  must_have "done flow" "$(A summary LC)" "done[ok]"
  mdl=$(A oversight-model LC)
  must_have "loop recorded" "$mdl" '"fixReturned": {'
  must_have "AC graph link" "$mdl" '"kind": "covers"'
  [ "$(printf '%s\n' "$mdl" | grep -c '"from": "AC-2"')" = 0 ] || { echo "FAIL: AC-2 has no mapping and must have no link" >&2; exit 1; }
  echo "oversight: summary, report and model over a full lifecycle passed"
}

scenario_isolation() {
  OVS_IGNORE_TOOL=1; scaffold; unset OVS_IGNORE_TOOL
  drive_to_review_fail
  expect_fail "a report inside run state was written" A report LC --out .agents/runs/LC/REPORT.html
  [ ! -e .agents/runs/LC/REPORT.html ] || { echo "FAIL: report written into run state" >&2; exit 1; }
  expect_fail "unknown option accepted" A report LC --nope
  expect_fail "an unknown task produced a report" A report NOPE
  # a broken tool, a dead event receiver and a failing report never fail the lifecycle
  export AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/events
  stub_curl "$base/stub-dead" dead; PATH=$base/stub-dead:$PATH; export PATH
  cp scripts/oversight/model.awk "$base/model.awk.keep"; printf 'BEGIN { this is not awk\n' > scripts/oversight/model.awk
  expect_fail "report with a broken tool should fail on its own" A report LC
  A handoff LC IMPLEMENTING >/dev/null
  solo FIX pass impl.txt 'impl: default for an empty key' impl.txt
  A handoff LC IMPLEMENTED >/dev/null
  gate_pass independent_reviewer REVIEW >/dev/null; gate_pass independent_qa QA >/dev/null; gate_pass independent_verifier VERIFY >/dev/null
  A handoff LC CODE_DONE >/dev/null; drive_to_done
  cp "$base/model.awk.keep" scripts/oversight/model.awk; unset AGENT_WORKFLOW_EVENTS_URL
  A validate LC >/dev/null
  # roles: every role may read the projection; only full_lifecycle may choose where a report goes (scenario_report_out)
  must_have "reviewer summary" "$(AS independent_reviewer summary LC)" "LC  COMPLEX"
  must_have "worker summary" "$(AS implementation_worker summary LC)" "LC  COMPLEX"
  AS explorer report LC >/dev/null
  echo "oversight: failure isolation and role access passed"
}

scenario_escape() {
  scaffold '<script>alert(1)</script> & "quoted"'
  drive_to_review_fail
  A report LC >/dev/null
  h=$(cat .agents/runtime/reports/LC.html)
  must_lack "unescaped script" "$h" "<script>alert(1)</script>"
  must_have "escaped script" "$h" "&lt;script&gt;alert(1)&lt;/script&gt;"
  echo "oversight: HTML escaping end to end passed"
}

scenario_events() {
  stub_curl "$base/stub-ok" ok; old_path=$PATH
  STUB_CURL_LOG=$base/ev; export STUB_CURL_LOG; : > "$base/ev.bodies"; : > "$base/ev.args"
  PATH=$base/stub-ok:$PATH; AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/events; AGENT_SESSION_PROVIDER=codex; AGENT_SESSION_ID=sess-1
  export PATH AGENT_WORKFLOW_EVENTS_URL AGENT_SESSION_PROVIDER AGENT_SESSION_ID
  scaffold   # classify, freeze and handoff IMPLEMENTING already emit events
  drive_to_review_fail; drive_fix_and_pass; drive_to_done; A report LC >/dev/null
  PATH=$old_path; unset AGENT_WORKFLOW_EVENTS_URL AGENT_SESSION_PROVIDER AGENT_SESSION_ID STUB_CURL_LOG
  b=$base/ev.bodies
  [ -s "$b" ] || { echo "FAIL: no workflow event reached the receiver" >&2; exit 1; }
  # schema: only the documented keys, one schema version, monotonic seq, provider session as given
  bad=$(grep -o '"[A-Za-z]*":' "$b" | tr -d '":' | sort -u | grep -vxE 'schema|event|runRef|seq|stage|status|gate|attempt|role|topology|findingsOpen|loop|fingerprint|reportAvailable|at|providerSession|provider|sessionId' || true)
  [ -z "$bad" ] || { echo "FAIL: undocumented event field: $bad" >&2; exit 1; }
  [ "$(grep -c '"schema":"workflow-event/1","event":"' "$b")" = "$(wc -l < "$b" | tr -d ' ')" ] || { echo "FAIL: an event lacks the schema header" >&2; exit 1; }
  [ "$(grep -c '"runRef":"LC"' "$b")" = "$(wc -l < "$b" | tr -d ' ')" ] || { echo "FAIL: runRef is not the task id" >&2; exit 1; }
  sed -n 's/.*"seq":\([0-9]*\),.*/\1/p' "$b" | awk 'NR > 1 && $1 <= prev { bad = 1 } { prev = $1 } END { exit bad }' || { echo "FAIL: event seq is not monotonic" >&2; exit 1; }
  [ "$(grep -c '"providerSession":{"provider":"codex","sessionId":"sess-1"}' "$b")" = "$(wc -l < "$b" | tr -d ' ')" ] || { echo "FAIL: provider session missing" >&2; exit 1; }
  seen=$(sed -n 's/.*"event":"\([a-z_]*\)".*"stage":"\([a-z_]*\)","status":"\([a-z_]*\)".*/\1\/\2\/\3/p' "$b")
  for want in stage/discover/started stage/evidence/completed stage/plan/completed stage/implement/started stage/implement/completed \
    gate/review/failed remediation/implement/started gate/review/passed gate/qa/passed gate/verify/passed stage/code_done/passed \
    stage/knowledge/skipped outcome/done/completed report/done/completed; do
    printf '%s\n' "$seen" | grep -qx "$want" || { echo "FAIL: missing event $want" >&2; exit 1; }
  done
  # emission is bounded: silent, no retry, hard time limit
  must_have "curl is silent" "$(cat "$base/ev.args")" "-s -o /dev/null"
  must_have "curl is time-limited" "$(cat "$base/ev.args")" "--max-time 0.3"
  must_have "curl connect is time-limited" "$(cat "$base/ev.args")" "--connect-timeout 0.2"
  must_have "curl does not retry" "$(cat "$base/ev.args")" "--retry 0"
  echo "oversight: workflow events through the whole lifecycle passed"
}

# The control plane needs only POSIX sh, awk, sed, git and shasum (curl is optional, for events), plus the few
# standard tools in PORTABLE_TOOLS (scripts/oversight-fixture.sh). This scenario proves it: summary, report and
# oversight-model run with a PATH that holds symlinks to exactly these tools (no go, node, python, jq, ruby, perl or
# curl on PATH; shasum is the control plane's own prerequisite and may itself be a script) under every awk engine found (BSD awk, mawk, gawk; OVS_EXTRA_AWKS adds more), and the output is
# byte-identical everywhere.
scenario_portable() {
  scaffold
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null; gate_fail independent_reviewer REVIEW >/dev/null
  printf -- '- AC-3: naïve résumé — 日本語 and <b>"quotes"</b> & more text so that the requirement is long enough to be cut by the table label\n' >> .agents/runs/LC/TASK.md
  ref_s=$(A summary LC); ref_m=$(A oversight-model LC); A report LC >/dev/null; ref_r=$(cat .agents/runtime/reports/LC.html)
  engines=$(awk_engines)
  n_eng=0
  for eng in $engines; do
    n_eng=$((n_eng + 1)); bin=$base/portable/$n_eng; mkdir -p "$bin"
    restricted_path "$bin" "$eng"
    got_s=$(env PATH="$bin" ./scripts/agent.sh summary LC) || { echo "FAIL: summary failed under restricted PATH with $eng" >&2; exit 1; }
    got_m=$(env PATH="$bin" ./scripts/agent.sh oversight-model LC) || { echo "FAIL: oversight-model failed under restricted PATH with $eng" >&2; exit 1; }
    rm -f .agents/runtime/reports/LC.html
    env PATH="$bin" ./scripts/agent.sh report LC >/dev/null || { echo "FAIL: report failed under restricted PATH with $eng" >&2; exit 1; }
    got_r=$(cat .agents/runtime/reports/LC.html)
    [ "$got_m" = "$ref_m" ] || { echo "FAIL: model differs under $eng" >&2; exit 1; }
    [ "$got_r" = "$ref_r" ] || { echo "FAIL: report bytes differ under $eng" >&2; exit 1; }
    [ "$(printf '%s\n' "$got_s" | grep -v '^report:')" = "$(printf '%s\n' "$ref_s" | grep -v '^report:')" ] || { echo "FAIL: summary differs under $eng" >&2; exit 1; }
    echo "oversight: portable run with awk $eng ($(env PATH="$bin" awk --version 2>&1 | head -n 1 | cut -c1-40)) identical"
  done
  [ "$n_eng" -ge 1 ] || { echo "FAIL: no awk engine found" >&2; exit 1; }
  # the event emitter without curl: silent, exit 0, nothing written
  AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/e env PATH="$bin" ./scripts/agent.sh summary LC >/dev/null
  echo "oversight: restricted-PATH portability passed ($n_eng awk engine(s); tools: $PORTABLE_TOOLS)"
}

# A report is a projection: --out must never reach run state, a tracked file or a symlink target, and only
# full_lifecycle may choose a path at all. Every refusal leaves the run directory byte-identical.
scenario_report_out() {
  OVS_IGNORE_TOOL=1; scaffold; unset OVS_IGNORE_TOOL
  drive_to_review_fail
  th=$(tree_hash .agents/runs/LC); ih=$(shasum -a 256 < impl.txt); sa=$(shasum -a 256 < scripts/agent.sh)
  same() { [ "$th" = "$(tree_hash .agents/runs/LC)" ] || { echo "FAIL: $1: run state changed" >&2; exit 1; }
    [ "$ih" = "$(shasum -a 256 < impl.txt)" ] || { echo "FAIL: $1: impl.txt changed" >&2; exit 1; }
    [ "$sa" = "$(shasum -a 256 < scripts/agent.sh)" ] || { echo "FAIL: $1: scripts/agent.sh changed" >&2; exit 1; }; }
  refuse() { d=$1; shift; expect_fail "$d" "$@"; same "$d"; }
  # 1. inode-based guard: case, `..`, absolute, symlinked directory, symlinked file, the directories themselves
  refuse "report over RUN.yaml" A report LC --out .agents/runs/LC/RUN.yaml
  refuse "report over RUN.yaml through .." A report LC --out .agents/../.agents/runs/LC/RUN.yaml
  refuse "report over RUN.yaml, absolute" A report LC --out "$PWD/.agents/runs/LC/RUN.yaml"
  refuse "report onto the runs directory" A report LC --out .agents/runs
  refuse "report onto a run directory" A report LC --out .agents/runs/LC
  refuse "report into a new directory under runs" A report LC --out .agents/runs/NEWDIR/x.html
  [ ! -e .agents/runs/NEWDIR ] || { echo "FAIL: a directory was created under .agents/runs" >&2; exit 1; }
  if [ .AGENTS/RUNS -ef .agents/runs ]; then   # a case-insensitive filesystem
    refuse "differently cased path over RUN.yaml" A report LC --out .AGENTS/RUNS/LC/RUN.yaml
    refuse "mixed case path over RUN.yaml" A report LC --out .Agents/Runs/LC/run.YAML
    refuse "cased absolute path over RUN.yaml" A report LC --out "$(printf '%s' "$PWD" | tr 'a-z' 'A-Z')/.agents/runs/LC/RUN.yaml"
  fi
  ln -s .agents/runs/LC linkdir
  refuse "symlinked directory over RUN.yaml" A report LC --out linkdir/RUN.yaml
  refuse "symlinked directory, new file" A report LC --out linkdir/NEW.html
  [ ! -e .agents/runs/LC/NEW.html ] || { echo "FAIL: report written into run state through a symlink" >&2; exit 1; }
  ln -s .agents/runs/LC/RUN.yaml linkfile.html
  refuse "symlinked file over RUN.yaml" A report LC --out linkfile.html
  [ -L linkfile.html ] || { echo "FAIL: the symlink was replaced" >&2; exit 1; }
  rm -f linkdir linkfile.html
  # 3. a planted temp-file symlink is never written through
  mkdir -p .agents/runtime/reports; ln -s "$PWD/.agents/runs/LC/RUN.yaml" .agents/runtime/reports/LC.html.tmp
  A report LC >/dev/null; same "planted .tmp symlink"
  head -c 15 .agents/runtime/reports/LC.html | grep -Fq '<!doctype html>' || { echo "FAIL: the report was not written" >&2; exit 1; }
  rm -f .agents/runtime/reports/LC.html.tmp
  # 2. only full_lifecycle chooses a path; no role may overwrite a tracked file
  for r in explorer architect independent_reviewer independent_qa independent_verifier implementation_worker; do
    refuse "$r report --out" env AGENT_ROLE=$r ./scripts/agent.sh report LC --out out-$r.txt
    [ ! -e out-$r.txt ] || { echo "FAIL: $r wrote through --out" >&2; exit 1; }
    refuse "$r report --out over a tracked file" env AGENT_ROLE=$r ./scripts/agent.sh report LC --out impl.txt
    refuse "$r report --out over scripts/agent.sh" env AGENT_ROLE=$r ./scripts/agent.sh report LC --out scripts/agent.sh
    AS $r report LC >/dev/null || { echo "FAIL: $r cannot write the default report" >&2; exit 1; }
  done
  refuse "full_lifecycle over a tracked file" A report LC --out impl.txt
  refuse "full_lifecycle over scripts/agent.sh" A report LC --out scripts/agent.sh
  refuse "full_lifecycle over a tracked file through .." A report LC --out scripts/../impl.txt
  if [ IMPL.TXT -ef impl.txt ]; then refuse "full_lifecycle over a tracked file, cased" A report LC --out IMPL.TXT; fi
  # an explicit path outside run state works for full_lifecycle, and the message shows the path as given
  out=$(A report LC --out out/ok.html); same "explicit --out"
  [ "$out" = "report written: out/ok.html" ] || { echo "FAIL: report message should show the given path (got: $out)" >&2; exit 1; }
  head -c 15 out/ok.html | grep -Fq '<!doctype html>' || { echo "FAIL: --out report missing" >&2; exit 1; }
  out=$(A report LC)
  [ "$out" = "report written: .agents/runtime/reports/LC.html" ] || { echo "FAIL: default report message must be repo-relative (got: $out)" >&2; exit 1; }
  echo "oversight: report --out guard, role gate, symlink and temp-file safety passed"
}

# decide and decision-outcome do not claim an implementation_worker that never acted.
scenario_event_role() {
  stub_curl "$base/stub-role" ok; old_path=$PATH
  STUB_CURL_LOG=$base/evr; export STUB_CURL_LOG; : > "$base/evr.bodies"; : > "$base/evr.args"
  PATH=$base/stub-role:$PATH; AGENT_WORKFLOW_EVENTS_URL=http://127.0.0.1:9/events; export PATH AGENT_WORKFLOW_EVENTS_URL
  scaffold
  sed 's/^  topology: standalone$/  topology: orchestrated/' .agents/runs/LC/RUN.yaml > "$base/RUN.new"; cat "$base/RUN.new" > .agents/runs/LC/RUN.yaml
  : > "$base/evr.bodies"
  A decide LC GREEN >/dev/null; A decision-outcome LC GREEN success >/dev/null
  PATH=$old_path; unset AGENT_WORKFLOW_EVENTS_URL STUB_CURL_LOG
  att=$(grep '"event":"attempt"' "$base/evr.bodies" || true)
  [ "$(printf '%s\n' "$att" | grep -c .)" = 2 ] || { echo "FAIL: expected two attempt events, got: $att" >&2; exit 1; }
  must_have "orchestrated topology reported" "$att" '"topology":"orchestrated"'
  must_lack "an implementation_worker that never acted" "$att" implementation_worker
  must_have "the emitting role is the invoker" "$att" '"role":"full_lifecycle"'
  echo "oversight: decide events do not claim an unrecorded role passed"
}

scenario_gate_fields() {
  scaffold
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null; reports FAIL
  bad() { printf 'summary: ran the full verification command set and inspected the whole diff of the current tree\nfindings: lookup in impl.txt returns the wrong value for an empty key\nseverity: %s\ncategory: %s\nfix_scope: impl.txt\nfix_instruction: make lookup return the documented default for an empty key\n' "$1" "$2" | AS independent_reviewer gate LC REVIEW fail; }
  expect_fail "unknown severity accepted" bad catastrophic correctness
  expect_fail "unknown category accepted" bad major vibes
  reports PASS
  expect_fail "severity on a passing gate accepted" sh -c "printf 'summary: ran the full verification command set and inspected the whole diff of the current tree\nseverity: major\n' | AGENT_ROLE=independent_reviewer ./scripts/agent.sh gate LC REVIEW pass"
  echo "oversight: gate severity and category validation passed"
}

scenario_measure() {
  scaffold
  drive_to_review_fail
  gf=$(wc -c < .agents/runs/LC/gates/001-REVIEW.yaml)
  drive_fix_and_pass
  gp=$(wc -c < .agents/runs/LC/gates/002-REVIEW.yaml)
  out=$(reports PASS; printf 'summary: ran the full verification command set and inspected the whole diff of the current tree\n' | AS independent_verifier gate LC VERIFY pass 2>&1 || true)
  drive_to_done
  printf 'gate_fail_record=%s\ngate_pass_record=%s\ncompletion_report=%s\nledger=%s\n' "$gf" "$gp" "$(wc -c < .agents/runs/LC/COMPLETION_REPORT.md)" "$(wc -c < .agents/runs/LC/LEDGER.log)"
  printf 'gate_pass_record_all=%s\n' "$(cat .agents/runs/LC/gates/*.yaml | wc -c)"
}

case "$mode" in
  measure) scenario_measure ;;
  projection|isolation|escape|gate_fields|events|portable|report_out|event_role) "scenario_$mode" ;;
  *)
    scenario_projection
    scenario_isolation
    scenario_escape
    scenario_gate_fields
    scenario_events
    scenario_event_role
    scenario_report_out
    scenario_portable
    echo 'oversight tests passed' ;;
esac

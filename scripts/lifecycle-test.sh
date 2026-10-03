#!/bin/sh
# Regression tests for the lifecycle in scripts/agent.sh: task classification
# selecting the pipeline (which artifacts freeze, which gates are required),
# REVIEW/QA/VERIFY gates bound to the exact application tree and to the role's
# report, mutation ownership under orchestrated topology, independence
# enforcement, the bounded fix loop, terminal FAILED/BLOCKED outcomes, runtime
# cleanup, the hash-chained lifecycle ledger (manual-rewind detection) and the
# scripted `amend` reopen. Run via `scripts/agent.sh test`, or directly.
#
# Each scenario builds a throwaway git repository with a `lifecycle_gates` run
# and drives the real agent.sh. Roles are the generic control-plane roles
# (full_lifecycle, implementation_worker, independent_reviewer, independent_qa,
# independent_verifier, explorer, architect); the control plane has no vendor
# concept, so "Claude standalone" and "Codex standalone" are the same
# full_lifecycle scenario, and the orchestrated scenarios below map an
# orchestrator that also reviews to full_lifecycle and the delegated
# implementer to implementation_worker. A scaffolded run is COMPLEX by default
# (REVIEW + QA + VERIFY), the pipeline that exercises every gate.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
base=$(mktemp -d /tmp/lifecycle-test.XXXXXX)
trap 'rm -rf "$base"' EXIT
n_fx=0

# --- helpers (all run inside the fixture repository) -------------------------
A() { ./scripts/agent.sh "$@"; }
AS() { r=$1; shift; AGENT_ROLE=$r ./scripts/agent.sh "$@"; }
# LC_TRACE=1 prints each expected failure's message so a reader can check the
# command failed for the intended reason, not for an unrelated error.
expect_fail() {
  d=$1; shift
  if ef_out=$("$@" 2>&1); then echo "FAIL: $d" >&2; exit 1; fi
  if [ -n "${LC_TRACE:-}" ]; then printf '  rejected [%s]: %s\n' "$d" "$(printf '%s' "$ef_out" | grep -v -E '^(freeze verified|planning freshness|scope check passed)' | tail -1 | cut -c1-220)"; fi
}
rv() { awk -v s="$1" -v k="$2" '$0 == s ":" { i=1; next } i && /^[^[:space:]]/ { exit } i && $0 ~ "^[[:space:]]*" k ":" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' .agents/runs/LC/RUN.yaml; }
expect_state() { [ "$(rv "$1" "$2")" = "$3" ] || { echo "FAIL: expected $1.$2=$3, got '$(rv "$1" "$2")'" >&2; exit 1; }; }
tree() { ./scripts/agent.sh patch-fingerprint LC; }

# One implementation window. wopen/wclose are what scripts/worker-run.sh does
# around the worker; wev is what the worker itself records.
wopen() { W=$(A window-open LC); }
wclose() { A window-close LC "$W" 0 >/dev/null; }
wev() { # phase result [target]
  e_ef=''; [ "$1" = RED ] && e_ef='expected_failure: TestImpl fails: lookup is not implemented in impl.txt yet'
  printf 'command: go test ./...\ntarget: %s\n%s\n' "${3:-impl.txt,impl_test.txt}" "$e_ef" | AGENT_ROLE=implementation_worker ./scripts/agent.sh worker-evidence LC "$1" "$2" >/dev/null
}
worker() { wopen; printf '%s\n' "$4" >> "$3"; wev "$1" "$2"; wclose; } # phase result file line
solo() { # phase result file line [target] — standalone: full_lifecycle implements and records its own evidence
  printf '%s\n' "$4" >> "$3"
  e_ef=''; [ "$1" = RED ] && e_ef='expected_failure: TestImpl fails: lookup is not implemented in impl.txt yet'
  printf 'command: go test ./...\ntarget: %s\n%s\n' "${5:-impl.txt,impl_test.txt}" "$e_ef" | AGENT_ROLE=full_lifecycle ./scripts/agent.sh worker-evidence LC "$1" "$2" >/dev/null
}
# A gate needs the role's own report (Verdict line included) in the run directory.
report_of() { case "$1" in REVIEW) echo REVIEW.md ;; QA) echo QA_REPORT.md ;; VERIFY) echo VERIFY.md ;; esac; }
write_gate_report() { printf '# %s\n\nVerdict: %s\n\nJudged the whole current tree.\n' "$1" "$2" > ".agents/runs/LC/$(report_of "$1")"; }
gate_pass() { write_gate_report "$2" PASS; AS "$1" gate LC "$2" pass <<EOF
summary: ran the full verification command set and inspected the whole diff of the current tree
EOF
}
gate_fail() { write_gate_report "$2" FAIL; AS "$1" gate LC "$2" fail <<EOF
summary: ran the full verification command set and inspected the whole diff of the current tree
findings: lookup in impl.txt returns the wrong value for an empty key in the reviewed tree
fix_scope: $3
fix_instruction: make lookup return the documented default for an empty key and cover it with a test
EOF
}
# Every gate a COMPLEX run requires, authored independently (ind) or by full_lifecycle itself (self).
pass_all() {
  if [ "$1" = ind ]; then gate_pass independent_reviewer REVIEW; gate_pass independent_qa QA; gate_pass independent_verifier VERIFY
  else gate_pass full_lifecycle REVIEW; gate_pass full_lifecycle QA; gate_pass full_lifecycle VERIFY; fi
}
amend_as() { printf 'reason: %s\nfix_scope: %s\nfix_instruction: %s\nauthorized_by: %s\n' "$2" "$3" "$4" "$5" | AGENT_ROLE=$1 ./scripts/agent.sh amend LC; }
write_report() {
  printf '%s\n' '# Completion Report: LC' '' '## Implementation Summary' 'impl.txt and impl_test.txt changed under the lifecycle gates.' '' \
    '## TDD Evidence' 'RED then GREEN recorded by the expected implementation owner.' '' '## Verification' 'All gates passed on the final tree.' '' \
    '## Review Result' 'Approved on the final tree.' '' '## QA Result' 'Every frozen QA scenario passed on the final tree.' '' '## Known Limitations / Follow-up' 'None.' "$@" > .agents/runs/LC/COMPLETION_REPORT.md
}
finish_done() {
  A knowledge-done LC not_applicable >/dev/null
  write_report "$@"
  A publish-completion-report LC markdown >/dev/null
  A handoff LC DONE >/dev/null
}

# --- task-source contract helpers --------------------------------------------
tc_status() { awk -v s="$2" '/^\*\*Status:\*\*/ { print "**Status:** " s; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
# Drive a freshly scaffolded fixture (frozen, IMPLEMENTING) to CODE_DONE in its topology.
tc_to_code_done() {
  if [ "$1" = orchestrated ]; then
    worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
    A handoff LC IMPLEMENTED >/dev/null
    pass_all ind; A handoff LC CODE_DONE >/dev/null
  else
    solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
    A handoff LC IMPLEMENTED >/dev/null
    pass_all self; A handoff LC CODE_DONE >/dev/null
  fi
}
tc_scaffold_done() { # topology — a contract-scheme fixture at CODE_DONE
  if [ "$1" = orchestrated ]; then scaffold orchestrated true yes; else scaffold standalone false yes; fi
  tc_to_code_done "$1"
}
tc_expect_msg() { # description pattern command... — the command must fail *for this reason*
  d=$1 pat=$2; shift 2
  if tm_out=$("$@" 2>&1); then echo "FAIL: $d (command succeeded)" >&2; exit 1; fi
  printf '%s' "$tm_out" | grep -Fq -- "$pat" || { echo "FAIL: $d (rejected for another reason: $(printf '%s' "$tm_out" | tail -1))" >&2; exit 1; }
}

# scaffold <topology> <independent:true|false> [todo-layout:yes|no] [class]
# — leaves the fixture at handoff IMPLEMENTING (frozen), cwd inside it. With
# todo-layout=yes the task file follows the todo/in-progress/done convention:
# committed under tasks/todo/, then moved (uncommitted, before baseline) to
# tasks/in-progress/, which is how a task file is normally started. The class
# (default COMPLEX) is recorded with `agent.sh classify` and the run carries
# exactly the artifacts that class requires.
scaffold() {
  topo=$1 indep=$2 layout=${3:-no} class=${4:-COMPLEX}
  tpath=tasks/LC.md; [ "$layout" = yes ] && tpath=tasks/in-progress/LC.md
  n_fx=$((n_fx + 1)); fx=$base/fx$n_fx
  mkdir -p "$fx/.agents/runs/LC" "$fx/.agents/modes" "$fx/.agents/task-integrations" "$fx/scripts" "$fx/tasks"
  cp "$root/scripts/agent.sh" "$root/scripts/worker-run.sh" "$root/scripts/exec-policy.sh" "$fx/scripts/"; [ ! -d "$root/scripts/oversight" ] || cp -R "$root/scripts/oversight" "$fx/scripts/"; [ ! -d "$root/.agents/skills" ] || cp -R "$root/.agents/skills" "$fx/.agents/"; cp "$root/.agents/config.yaml" "$root/.agents/ENGINEERING.md" "$root/.agents/VERIFICATION.md" "$fx/.agents/"
  cp "$root/.agents/task-integrations/markdown.sh" "$fx/.agents/task-integrations/"; chmod +x "$fx/.agents/task-integrations/markdown.sh"
  for m in "$root/.agents/modes/"*.yaml; do
    sed "s/independent: true/independent: $indep/; s/independent_verifier: true/independent_verifier: $indep/" "$m" > "$fx/.agents/modes/$(basename "$m")"
  done
  printf 'LC\n' > "$fx/.agents/ACTIVE_RUN"
  printf '# Task: LC\n\n## Acceptance criteria\n\n- AC-1: lookup behavior\n' > "$fx/.agents/runs/LC/TASK.md"
  case "$class" in TRIVIAL) ;; *) printf '# Evidence\n' > "$fx/.agents/runs/LC/EVIDENCE.md"; printf '# QA plan\n\n- QA-1 (AC-1): lookup returns the stored value\n' > "$fx/.agents/runs/LC/QA_PLAN.md" ;; esac
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '---' '# Plan' '' '## Architecture' 'one storage map; no new module' > "$fx/.agents/runs/LC/PLAN.md"
  printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' "  path: $tpath" '  revision: PENDING' \
    'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' "  topology: $topo" \
    'pipeline:' '  classification: PENDING' '  review: PENDING' \
    'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  qa_plan_sha256: PENDING' '  policy_sha256: PENDING' '  pipeline: PENDING' \
    'baseline:' '  status: pending' \
    'handoff:' '  state: PLANNED' '  implemented_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
    'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
    'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING' \
    'lifecycle_gates:' '  required: true' > "$fx/.agents/runs/LC/RUN.yaml"
  cd "$fx"
  git init -q -b main; git config user.email lifecycle@example.invalid; git config user.name fixture
  printf '.agents/runs/\n' >> .git/info/exclude                                  # runs are gitignored in the real repository
  : > impl.txt; : > impl_test.txt
  if [ "$layout" = yes ]; then
    mkdir -p tasks/todo; printf '%s\n' '# LC task' '' '**Status:** todo' '' '## Requirements' '' '- lookup returns the documented default for an empty key' > tasks/todo/LC.md
  else
    printf '# LC task\n' > tasks/LC.md
  fi
  git add -- .agents scripts tasks impl.txt impl_test.txt; git commit -qm baseline
  if [ "$layout" = yes ]; then mkdir -p tasks/in-progress; git mv tasks/todo/LC.md tasks/in-progress/LC.md; tc_status tasks/in-progress/LC.md in-progress; fi
  A classify LC "$class" >/dev/null
  A baseline LC >/dev/null; [ "$class" = TRIVIAL ] || printf 'discovered\n' >> .agents/runs/LC/EVIDENCE.md; printf 'planned\n' >> .agents/runs/LC/PLAN.md
  A freeze LC >/dev/null; A handoff LC IMPLEMENTING >/dev/null
}

# --- scenarios ---------------------------------------------------------------

# LC_ONLY=<substring> runs only the scenarios whose function name contains it.
run_sc() { if [ -z "${LC_ONLY:-}" ] || printf '%s' "$1" | grep -q -- "$LC_ONLY"; then "$@"; fi; }

# Standalone: full_lifecycle owns everything and may change application code
# and tests directly at any point, including after the gates; independence is
# not required by this run's policy. The same scenario is what "Claude
# standalone" and "Codex standalone" both are — the control plane is vendor-neutral.
scenario_standalone() {
  scaffold standalone false; label=$1 full=${2:-full}
  solo RED fail impl_test.txt "test ($label): lookup returns the stored value"
  solo GREEN pass impl.txt "impl ($label): lookup returns the stored value"
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "CODE_DONE without any gate" A handoff LC CODE_DONE
  gate_pass full_lifecycle REVIEW                                                # independent=false: self-review is enough
  expect_fail "CODE_DONE with only the review gate" A handoff LC CODE_DONE
  gate_pass full_lifecycle QA
  expect_fail "CODE_DONE without the VERIFY gate" A handoff LC CODE_DONE
  gate_pass full_lifecycle VERIFY
  if [ "$full" = short ]; then
    A handoff LC CODE_DONE >/dev/null; finish_done; A delivery-check LC >/dev/null
    echo "lifecycle: standalone ($label) passed"; return 0
  fi
  # a change after the gates (standalone may make it) voids all of them; nothing carries over
  printf 'late tweak\n' >> impl.txt
  expect_fail "stale gates accepted by verify-handoff" A verify-handoff LC
  expect_fail "a gate recorded on a tree changed since IMPLEMENTED" gate_pass full_lifecycle QA
  expect_fail "CODE_DONE on a tree changed since IMPLEMENTED" A handoff LC CODE_DONE
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "CODE_DONE using the passes for the older tree" A handoff LC CODE_DONE
  pass_all self
  printf 'another tweak\n' >> impl.txt                                          # a change after all gates voids them all
  expect_fail "CODE_DONE on passes for an older tree" A handoff LC CODE_DONE
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "CODE_DONE on stale passes" A handoff LC CODE_DONE
  pass_all self; A handoff LC CODE_DONE >/dev/null
  # a report edited after its gate voids that gate, even though the tree is unchanged
  printf 'edited after the gate\n' >> .agents/runs/LC/QA_REPORT.md
  expect_fail "an edited QA report still counted" A verify-handoff LC
  write_gate_report QA PASS; A verify-handoff LC >/dev/null
  finish_done
  A delivery-check LC >/dev/null; A validate LC >/dev/null; A verify-gates LC >/dev/null
  echo "lifecycle: standalone ($label) passed"
}

# Standalone with review.independent / qa.independent / verification.independent_verifier
# true: self-authored gates never satisfy them; the independent roles do; and every
# non-implementation role is a read-only observer.
scenario_independence() {
  scaffold standalone true
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "self-review satisfied review.independent" gate_pass full_lifecycle REVIEW
  expect_fail "self-QA satisfied qa.independent" gate_pass full_lifecycle QA
  expect_fail "self-verification satisfied verification.independent_verifier" gate_pass full_lifecycle VERIFY
  expect_fail "QA role recorded a REVIEW gate" gate_pass independent_qa REVIEW
  expect_fail "reviewer role recorded a QA gate" gate_pass independent_reviewer QA
  expect_fail "verifier role recorded a QA gate" gate_pass independent_verifier QA
  expect_fail "QA role recorded a VERIFY gate" gate_pass independent_qa VERIFY
  expect_fail "explorer recorded a gate" gate_pass explorer QA
  expect_fail "architect recorded a gate" gate_pass architect REVIEW
  expect_fail "implementation_worker recorded a gate" gate_pass implementation_worker QA
  pass_all ind
  for g in REVIEW QA VERIFY; do
    gf=$(ls .agents/runs/LC/gates/*-$g.yaml); cp "$gf" "$base/gate.bak"
    sed 's/^role: .*/role: "full_lifecycle"/' "$base/gate.bak" > "$gf"
    expect_fail "hand-relabelled self-authored $g gate counted as independent" A handoff LC CODE_DONE
    cp "$base/gate.bak" "$gf"
  done
  A handoff LC CODE_DONE >/dev/null
  # role boundaries: none of them may move the lifecycle or touch the run's contract
  for r in independent_reviewer independent_qa independent_verifier explorer architect; do
    expect_fail "$r moved the lifecycle" AS "$r" handoff LC DONE
    expect_fail "$r froze" AS "$r" freeze LC
    expect_fail "$r classified" AS "$r" classify LC TRIVIAL
    expect_fail "$r reopened a run" AS "$r" amend LC
    expect_fail "$r terminated a run" sh -c "printf 'reason: x\nevidence: y\n' | AGENT_ROLE=$r ./scripts/agent.sh terminate LC BLOCKED"
    expect_fail "$r cleaned up a run" AS "$r" cleanup LC
    expect_fail "$r recorded implementation evidence" sh -c "printf 'command: x\ntarget: impl.txt\n' | AGENT_ROLE=$r ./scripts/agent.sh worker-evidence LC GREEN pass"
    AS "$r" verify-handoff LC >/dev/null; AS "$r" pipeline LC >/dev/null
  done
  finish_done; A delivery-check LC >/dev/null
  for r in independent_reviewer independent_qa independent_verifier explorer architect; do AS "$r" validate LC >/dev/null; done
  echo "lifecycle: independence enforcement passed"
}

# The orchestrated topology end to end (one agent orchestrates, a separate
# implementation_worker writes the code, independent roles judge), with the
# sequence: worker implementation -> review FAIL -> worker fix -> review PASS ->
# QA FAIL -> worker fix -> all gates PASS -> CODE_DONE -> DONE -> reopen ->
# worker fix -> all gates -> CODE_DONE -> DONE.
scenario_orchestrated_loop() {
  scaffold orchestrated true
  # The orchestrator (full_lifecycle) may not author application/test changes.
  printf 'orchestrator wrote this\n' >> impl_test.txt
  expect_fail "worker window opened over an orchestrator edit" A window-open LC
  printf 'command: x\ntarget: impl_test.txt\nexpected_failure: TestImpl fails: lookup is not implemented in impl.txt yet\n' > "$base/ev.in"
  expect_fail "orchestrator-authored RED evidence accepted under orchestrated" sh -c "./scripts/agent.sh worker-evidence LC RED fail < '$base/ev.in'"
  git checkout -q -- impl_test.txt
  # The implementation_worker owns RED / GREEN.
  worker RED fail impl_test.txt 'test: lookup returns the stored value'
  worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null; expect_state handoff state IMPLEMENTED
  # Gate authorship.
  expect_fail "orchestrator self-review satisfied review.independent" gate_pass full_lifecycle REVIEW
  expect_fail "implementation_worker recorded a gate" gate_pass implementation_worker REVIEW
  expect_fail "CODE_DONE with no gates" A handoff LC CODE_DONE
  # REVIEW FAIL -> bounded finding/fix contract -> the orchestrator may not fix it.
  gate_fail independent_reviewer REVIEW impl.txt
  expect_fail "a second gate on a tree with an open finding" gate_pass independent_qa QA
  expect_fail "CODE_DONE with an open finding" A handoff LC CODE_DONE
  A handoff LC IMPLEMENTING >/dev/null; expect_state handoff state IMPLEMENTING
  cp impl.txt "$base/impl.saved"; printf 'orchestrator quick fix\n' >> impl.txt
  expect_fail "orchestrator's own fix reached IMPLEMENTED" A handoff LC IMPLEMENTED
  expect_fail "worker window absorbed the orchestrator's fix" A window-open LC
  cp "$base/impl.saved" impl.txt
  A window-open LC >/dev/null                                            # tree is the last attested one again
  worker FIX pass impl.txt 'impl: lookup returns the documented default for an empty key'
  A handoff LC IMPLEMENTED >/dev/null
  gate_pass independent_reviewer REVIEW
  # QA FAIL -> worker fix -> every gate runs again on the new tree.
  gate_fail independent_qa QA impl_test.txt
  expect_fail "CODE_DONE with a failing QA" A handoff LC CODE_DONE
  A handoff LC IMPLEMENTING >/dev/null
  worker FIX pass impl_test.txt 'test: an empty key returns the documented default'
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "CODE_DONE on the review pass for the older tree" A handoff LC CODE_DONE
  gate_pass independent_reviewer REVIEW; gate_pass independent_qa QA
  expect_fail "CODE_DONE before the VERIFY gate" A handoff LC CODE_DONE
  gate_pass independent_verifier VERIFY; A handoff LC CODE_DONE >/dev/null
  A verify-gates LC >/dev/null
  # DONE
  expect_fail "DONE before knowledge/report" A handoff LC DONE
  finish_done; A delivery-check LC >/dev/null; A validate LC >/dev/null; A verify-seal LC >/dev/null
  expect_state handoff state DONE

  # A manual lifecycle rewind is detected everywhere it would matter.
  cp .agents/runs/LC/RUN.yaml "$base/run.bak"
  sed '/^handoff:$/,/^[^ ]/ s/state: ".*"/state: "IMPLEMENTING"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-rewound handoff.state passed verify-seal" A verify-seal LC
  expect_fail "hand-rewound handoff.state passed validate" A validate LC
  expect_fail "hand-rewound handoff.state passed delivery-check" A delivery-check LC
  expect_fail "transition layered on a hand-rewound state" A handoff LC IMPLEMENTED
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  sed 's/published: "true"/published: "false"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-edited completion_report.published passed verify-seal" A verify-seal LC
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  sed 's/^  state: "CODE_DONE"/  state: "PLANNING"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-edited execution.state passed verify-seal" A verify-seal LC
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  sed '/^pipeline:$/,/^[^ ]/ s/classification: ".*"/classification: "TRIVIAL"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-edited classification passed verify-seal" A verify-seal LC
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  A verify-seal LC >/dev/null

  # The supported reopen: explicit, authorized, audited, fail-closed.
  cp impl.txt "$base/impl.final"
  expect_fail "amend by a non-orchestrator role" amend_as implementation_worker 'post-DONE review found the key handling is still wrong for whitespace' impl.txt 'trim the key before lookup and add a regression test for it' 'the user'
  expect_fail "amend without an authorizer" amend_as full_lifecycle 'post-DONE review found the key handling is still wrong for whitespace' impl.txt 'trim the key before lookup and add a regression test for it' ''
  expect_fail "amend with a generic reason" amend_as full_lifecycle 'not needed' impl.txt 'trim the key before lookup and add a regression test for it' 'the user'
  expect_fail "amend with fix_scope outside the frozen plan" amend_as full_lifecycle 'post-DONE review found the key handling is still wrong for whitespace' outside.txt 'trim the key before lookup and add a regression test for it' 'the user'
  amend_as full_lifecycle 'post-DONE review found the key handling is still wrong for whitespace' impl.txt 'trim the key before lookup and add a regression test for it' 'the user (explicit reopen request)' >/dev/null
  expect_state execution state AMENDING; expect_state handoff state IMPLEMENTING; expect_state completion_report published false
  expect_state execution knowledge_state not_started; expect_state handoff code_done_patch_sha256 PENDING
  grep -q '^previous_handoff_state: "DONE"' .agents/runs/LC/gates/*-REOPEN.yaml
  grep -q '^previous_completion_receipt: "tasks/LC.md#' .agents/runs/LC/gates/*-REOPEN.yaml
  grep -q '^authorized_by: the user' .agents/runs/LC/gates/*-REOPEN.yaml
  ls .agents/runs/LC/gates/*-REOPEN.completion-report.md >/dev/null
  expect_fail "amend on a run that is already reopened" amend_as full_lifecycle 'another reopen while one is already open now' impl.txt 'this must be refused because the run is not completed' 'the user'
  expect_fail "DONE straight after reopen" A handoff LC DONE
  # The reopened fix is worker-owned like any other change.
  printf 'orchestrator hot-fix\n' >> impl.txt
  expect_fail "orchestrator hot-fix reached IMPLEMENTED after reopen" A handoff LC IMPLEMENTED
  cp "$base/impl.final" impl.txt
  worker FIX pass impl.txt 'impl: trim the key before lookup'
  A handoff LC IMPLEMENTED >/dev/null
  pass_all ind; A handoff LC CODE_DONE >/dev/null
  A knowledge-done LC not_applicable >/dev/null; write_report
  expect_fail "report without Reopen History accepted for a reopened run" A publish-completion-report LC markdown
  write_report '' '## Reopen History' 'Reopened once after DONE: whitespace keys; fixed by the worker; re-reviewed and re-verified.'
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
  A delivery-check LC >/dev/null; A validate LC >/dev/null; A verify-seal LC >/dev/null
  # Audit history is preserved and tamper-evident.
  [ "$(grep -c 'event=REOPEN' .agents/runs/LC/LEDGER.log)" = 1 ]
  grep -q 'event=handoff:DONE' .agents/runs/LC/LEDGER.log
  ls .agents/runs/LC/gates/*-REOPEN.yaml >/dev/null
  cp .agents/runs/LC/LEDGER.log "$base/ledger.bak"
  sed '2s/role=[a-z_]*/role=implementation_worker/' "$base/ledger.bak" > .agents/runs/LC/LEDGER.log
  expect_fail "edited ledger entry passed verify-seal" A verify-seal LC
  sed '2d' "$base/ledger.bak" > .agents/runs/LC/LEDGER.log
  expect_fail "deleted ledger entry passed verify-seal" A verify-seal LC
  cp "$base/ledger.bak" .agents/runs/LC/LEDGER.log; A verify-seal LC >/dev/null
  # Runtime cleanup: the last act. The run directory is deleted and the selector cleared.
  expect_fail "cleanup by a non-orchestrator" AS independent_verifier cleanup LC
  cp impl.txt "$base/impl.done"; printf 'edited after DONE\n' >> impl.txt
  expect_fail "cleanup accepted a run whose tree changed after DONE" A cleanup LC
  [ -d .agents/runs/LC ]
  cp "$base/impl.done" impl.txt
  A cleanup LC >/dev/null
  [ ! -e .agents/runs/LC ] && [ -z "$(sed '/^[[:space:]]*$/d' .agents/ACTIVE_RUN)" ]
  A status | grep -Fxq 'active_task=none'
  echo "lifecycle: orchestrated loop, reopen, ledger and cleanup passed"
}

# Orchestrated attribution: any change to the application/test tree made
# outside the implementation_worker is detected, before and after the gates.
scenario_attribution() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  pass_all self                                                                   # independent=false keeps self-authored gates valid
  cp impl.txt "$base/impl.keep"; printf 'late orchestrator edit\n' >> impl.txt
  expect_fail "post-gate orchestrator edit passed verify-handoff" A verify-handoff LC
  expect_fail "a gate recorded over an unattributed edit" gate_pass full_lifecycle VERIFY
  expect_fail "CODE_DONE over an unattributed edit" A handoff LC CODE_DONE
  expect_fail "re-asserting IMPLEMENTED laundered an unattributed edit" A handoff LC IMPLEMENTED
  expect_fail "worker window closed outside IMPLEMENTING" A window-close LC "$(tree)" 0
  cp "$base/impl.keep" impl.txt
  A verify-handoff LC >/dev/null                                                  # tree is the attested one again
  A handoff LC CODE_DONE >/dev/null
  echo "lifecycle: orchestrated attribution passed"
}

# Bounded fix loop: a fix stays inside its finding's fix_scope, at most
# max_bounded_fix_attempts fixes per frozen plan, and an explicit plan
# amendment (refreeze) is the escalation valve that returns the run to
# IMPLEMENTING with a fresh budget.
scenario_bounded_fix() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle REVIEW impl.txt; A handoff LC IMPLEMENTING >/dev/null
  cp impl_test.txt "$base/test.keep"
  worker FIX pass impl_test.txt 'test: tweak outside the finding'
  expect_fail "fix outside the finding's fix_scope reached IMPLEMENTED" A handoff LC IMPLEMENTED
  wopen; cp "$base/test.keep" impl_test.txt; printf 'impl: default for an empty key\n' >> impl.txt; wev FIX pass impl.txt; wclose
  A handoff LC IMPLEMENTED >/dev/null                                             # fix #1, inside fix_scope
  gate_fail full_lifecycle QA impl.txt; A handoff LC IMPLEMENTING >/dev/null      # finding #2 — any gate's finding counts
  expect_fail "IMPLEMENTED with no change since the finding" A handoff LC IMPLEMENTED
  worker FIX pass impl.txt 'impl: second attempt at the empty key default'
  A handoff LC IMPLEMENTED >/dev/null                                             # fix #2
  gate_fail full_lifecycle VERIFY impl.txt                                        # finding #3: fixes exhausted
  expect_fail "a third fix was allowed" A handoff LC IMPLEMENTING
  expect_fail "FAILED accepted with a specific reason but no evidence" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: \n' | ./scripts/agent.sh terminate LC FAILED"
  # Escalation: an explicit, authorized plan amendment and refreeze.
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: the finding needs the plan to cover the empty-key contract\n' > .agents/runs/LC/amendments/001.md
  printf 'amended: empty-key contract\n' >> .agents/runs/LC/PLAN.md
  expect_fail "refreeze without an amendment file" A refreeze LC missing.md
  A refreeze LC 001.md >/dev/null
  expect_state handoff state IMPLEMENTING; expect_state handoff implemented_patch_sha256 PENDING
  expect_fail "IMPLEMENTED on pre-amendment evidence" A handoff LC IMPLEMENTED
  worker RED fail impl_test.txt 'test: empty key returns the documented default'
  worker GREEN pass impl.txt 'impl: empty key returns the documented default'
  A handoff LC IMPLEMENTED >/dev/null
  pass_all self; A handoff LC CODE_DONE >/dev/null
  A knowledge-done LC not_applicable >/dev/null; write_report '' '## Amendments' 'Amendment 001 after three failing gates.'
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
  A validate LC >/dev/null
  echo "lifecycle: bounded fix loop and escalation passed"
}

# The retry limit ends a run: FAILED only once the bounded fix budget is exhausted,
# BLOCKED for an outside blocker; both need a reason and evidence, are terminal, and are
# disposed of by cleanup. Nothing moves a terminal run.
scenario_terminal() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle QA impl.txt
  expect_fail "FAILED accepted while the fix budget is not exhausted" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: gate 001-QA failed the empty-key scenario twice\n' | ./scripts/agent.sh terminate LC FAILED"
  A handoff LC IMPLEMENTING >/dev/null; worker FIX pass impl.txt 'impl: first attempt'; A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle QA impl.txt; A handoff LC IMPLEMENTING >/dev/null; worker FIX pass impl.txt 'impl: second attempt'; A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle QA impl.txt
  expect_fail "a third fix was allowed" A handoff LC IMPLEMENTING
  expect_fail "terminate without a reason" sh -c "printf 'reason: no\nevidence: gate 003-QA failed the empty-key scenario a third time\n' | ./scripts/agent.sh terminate LC FAILED"
  expect_fail "terminate without evidence" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: none\n' | ./scripts/agent.sh terminate LC FAILED"
  expect_fail "terminate by a non-orchestrator" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: gate 003-QA failed the empty-key scenario a third time\n' | AGENT_ROLE=independent_qa ./scripts/agent.sh terminate LC FAILED"
  expect_fail "an unknown outcome was accepted" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: gate 003-QA failed the empty-key scenario a third time\n' | ./scripts/agent.sh terminate LC DONE"
  printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: gate 003-QA failed the empty-key scenario a third time\n' | A terminate LC FAILED >/dev/null
  expect_state execution state FAILED
  expect_fail "a terminal run accepted a handoff" A handoff LC IMPLEMENTING
  expect_fail "a terminal run accepted a gate" gate_pass full_lifecycle QA
  expect_fail "a terminal run was reclassified" A classify LC STANDARD
  expect_fail "a terminal run was terminated again" sh -c "printf 'reason: the empty-key contract cannot be met within the frozen plan scope\nevidence: gate 003-QA failed the empty-key scenario a third time\n' | ./scripts/agent.sh terminate LC BLOCKED"
  A verify-seal LC >/dev/null
  grep -q 'event=terminate' .agents/runs/LC/LEDGER.log
  A cleanup LC >/dev/null; [ ! -e .agents/runs/LC ]

  # BLOCKED needs no exhausted budget: an environment/tooling blocker is not an implementation failure.
  scaffold standalone false
  expect_fail "cleanup of a run that is neither DONE nor terminal" A cleanup LC
  printf 'reason: the verification toolchain is unavailable in this environment\nevidence: go test exited 127 because the go binary is missing\n' | A terminate LC BLOCKED >/dev/null
  expect_state execution state BLOCKED
  A cleanup LC >/dev/null; [ ! -e .agents/runs/LC ]
  echo "lifecycle: terminal outcomes and cleanup passed"
}

# Task classification selects the pipeline. TRIVIAL: no evidence, no QA plan, no review, no QA —
# implement, then the VERIFY gate.
scenario_pipeline_trivial() {
  scaffold standalone false no TRIVIAL
  A pipeline LC | grep -Fxq 'gates=VERIFY'; A pipeline LC | grep -Fxq 'evidence=no'; A pipeline LC | grep -Fxq 'qa_plan=no'
  [ ! -e .agents/runs/LC/EVIDENCE.md ] && [ ! -e .agents/runs/LC/QA_PLAN.md ]
  expect_state freeze evidence_sha256 not_required; expect_state freeze qa_plan_sha256 not_required
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  expect_fail "CODE_DONE without the VERIFY gate" A handoff LC CODE_DONE
  expect_fail "a QA gate on a TRIVIAL run" gate_pass full_lifecycle QA
  expect_fail "a REVIEW gate on a TRIVIAL run" gate_pass full_lifecycle REVIEW
  rm -f .agents/runs/LC/QA_REPORT.md .agents/runs/LC/REVIEW.md                    # the failed attempts left their (unrequired) reports behind
  gate_pass full_lifecycle VERIFY
  A handoff LC CODE_DONE >/dev/null
  # Artifacts the pipeline does not require are not run metadata: they are unexpected files.
  printf '# stray\n' > .agents/runs/LC/QA_PLAN.md
  tc_expect_msg "a QA_PLAN.md on a TRIVIAL run passed verify-scope" 'unexpected run artifact' A verify-scope LC
  rm .agents/runs/LC/QA_PLAN.md
  # No Review Result / QA Result section is required of the completion report.
  A knowledge-done LC not_applicable >/dev/null
  printf '%s\n' '# Completion Report: LC' '' '## Implementation Summary' 'impl.txt and impl_test.txt changed under the TRIVIAL pipeline.' '' '## TDD Evidence' 'RED then GREEN recorded by full_lifecycle.' '' '## Verification' 'The VERIFY gate passed on the final tree.' '' '## Known Limitations / Follow-up' 'None.' > .agents/runs/LC/COMPLETION_REPORT.md
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
  A validate LC >/dev/null; A delivery-check LC >/dev/null
  printf '# stray\n' > .agents/runs/LC/QA_PLAN.md
  tc_expect_msg "a QA_PLAN.md on a TRIVIAL run passed validate" 'unexpected run artifact' A validate LC
  rm .agents/runs/LC/QA_PLAN.md; printf '# stray\n' > .agents/runs/LC/EVIDENCE.md
  tc_expect_msg "an EVIDENCE.md on a TRIVIAL run passed validate" 'unexpected run artifact' A validate LC
  rm .agents/runs/LC/EVIDENCE.md; A validate LC >/dev/null
  echo "lifecycle: TRIVIAL pipeline passed"
}

# STANDARD: evidence + a frozen QA plan, QA and VERIFY gates; REVIEW only when the run opts in.
scenario_pipeline_standard() {
  scaffold standalone false no STANDARD
  A pipeline LC | grep -Fxq 'gates=QA VERIFY'; A pipeline LC | grep -Fxq 'review=no'; A pipeline LC | grep -Fxq 'qa_plan=yes'
  expect_fail "a REVIEW gate on a STANDARD run that did not opt in" gate_pass full_lifecycle REVIEW
  rm -f .agents/runs/LC/REVIEW.md
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_pass full_lifecycle QA
  expect_fail "CODE_DONE without the VERIFY gate" A handoff LC CODE_DONE
  gate_pass full_lifecycle VERIFY
  A handoff LC CODE_DONE >/dev/null
  # The QA plan is frozen with the plan: nobody — including the implementer — edits it afterwards.
  printf -- '- QA-2: weakened criterion added after freeze\n' >> .agents/runs/LC/QA_PLAN.md
  tc_expect_msg "an edited QA plan passed verify-freeze" 'freeze mismatch: qa_plan' A verify-freeze LC
  tc_expect_msg "an edited QA plan passed freshness" 'freeze mismatch: qa_plan' A freshness LC
  tc_expect_msg "an edited QA plan allowed DONE" 'freeze mismatch: qa_plan' A knowledge-done LC not_applicable
  sed '$d' .agents/runs/LC/QA_PLAN.md > "$base/qa_plan.restored" && cp "$base/qa_plan.restored" .agents/runs/LC/QA_PLAN.md
  A verify-freeze LC >/dev/null
  echo "lifecycle: STANDARD pipeline passed"
}

# Classification rules: classify is orchestrator-only, review is an option only where the pipeline says
# optional, reclassifying after freeze voids the freeze until an amendment and refreeze, and freezing is
# refused when the artifacts do not match the class.
scenario_classification() {
  scaffold standalone false no STANDARD
  expect_fail "an unknown class was accepted" A classify LC EPIC
  expect_fail "the review option on a class that fixes review" A classify LC COMPLEX review
  expect_fail "an unknown option was accepted" A classify LC STANDARD strict
  # STANDARD may opt into review: REVIEW then joins the required gates.
  A classify LC STANDARD review >/dev/null
  expect_fail "a reclassification after freeze passed verify-freeze" A verify-freeze LC
  expect_fail "a reclassification after freeze allowed a handoff" A handoff LC IMPLEMENTED
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: the change touches shared state, so it needs a review gate\n' > .agents/runs/LC/amendments/001.md
  for n in 002 003 004; do printf '# amendment %s: reclassification step\n' $n > .agents/runs/LC/amendments/$n.md; done
  A refreeze LC 001.md >/dev/null; A verify-freeze LC >/dev/null
  A pipeline LC | grep -Fxq 'gates=REVIEW QA VERIFY'
  # COMPLEX/CRITICAL need the Architect's section; a plan without it cannot be frozen.
  A classify LC COMPLEX >/dev/null
  cp .agents/runs/LC/PLAN.md "$base/plan.saved"
  sed '/^## Architecture/,$d' "$base/plan.saved" > .agents/runs/LC/PLAN.md
  expect_fail "COMPLEX froze a plan with no Architecture section" A refreeze LC 002.md
  cp "$base/plan.saved" .agents/runs/LC/PLAN.md
  A refreeze LC 002.md >/dev/null; A verify-freeze LC >/dev/null
  A classify LC CRITICAL >/dev/null; A refreeze LC 003.md >/dev/null; A pipeline LC | grep -Fxq 'max_explorers=3'
  # A missing QA plan (or evidence) cannot be frozen; a class that does not need them refuses to freeze with them.
  mv .agents/runs/LC/QA_PLAN.md "$base/qa_plan.saved"
  expect_fail "froze a STANDARD-or-above run with no QA plan" A refreeze LC 004.md
  mv "$base/qa_plan.saved" .agents/runs/LC/QA_PLAN.md
  A classify LC TRIVIAL >/dev/null
  expect_fail "TRIVIAL froze with EVIDENCE.md and QA_PLAN.md present" A refreeze LC 004.md
  # The TRIVIAL bound is mechanical: a plan with more scope paths is not TRIVIAL.
  rm .agents/runs/LC/EVIDENCE.md .agents/runs/LC/QA_PLAN.md
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '  - path: third.txt' '    criteria: [AC-1]' '---' '# Plan' > .agents/runs/LC/PLAN.md
  expect_fail "TRIVIAL froze a plan with three scope paths" A refreeze LC 004.md
  # An unclassified run cannot freeze at all.
  cp .agents/runs/LC/RUN.yaml "$base/run.saved"
  sed '/^pipeline:$/,/^[^ ]/ s/classification: ".*"/classification: "PENDING"/' "$base/run.saved" > .agents/runs/LC/RUN.yaml
  expect_fail "froze an unclassified run" A refreeze LC 004.md
  cp "$base/run.saved" .agents/runs/LC/RUN.yaml
  # classify of a completed run is refused
  scaffold standalone false
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null; pass_all self; A handoff LC CODE_DONE >/dev/null
  expect_fail "a completed run was reclassified" A classify LC TRIVIAL
  echo "lifecycle: classification rules passed"
}

# Reopen that needs a plan change: fix_scope beyond the frozen plan is refused
# unless plan_change is declared, and the plan itself only changes through an
# amendment file + refreeze, which the reopen (execution AMENDING) permits.
scenario_amend_plan_change() {
  scaffold standalone false
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null; pass_all self
  A handoff LC CODE_DONE >/dev/null; finish_done
  expect_fail "reopen naming a path outside the frozen plan without plan_change" amend_as full_lifecycle 'the review found a missing helper file the plan did not cover' extra.txt 'add extra.txt with the helper and cover it with a test' 'the user'
  printf 'reason: the review found a missing helper file the plan did not cover\nfix_scope: extra.txt\nfix_instruction: add extra.txt with the helper and cover it with a test\nauthorized_by: the user\nplan_change: yes\n' | A amend LC >/dev/null
  expect_state execution state AMENDING
  expect_fail "plain freeze on a reopened run" A freeze LC
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: add extra.txt to scope\n' > .agents/runs/LC/amendments/001.md
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '  - path: extra.txt' '    criteria: [AC-1]' '---' '# Plan' '' '## Architecture' 'amended: one helper file' > .agents/runs/LC/PLAN.md
  A refreeze LC 001.md >/dev/null; expect_state handoff state IMPLEMENTING
  solo RED fail impl_test.txt 'test: helper returns the stored value' impl.txt,impl_test.txt,extra.txt; solo GREEN pass extra.txt 'helper: returns the stored value' impl.txt,impl_test.txt,extra.txt
  A handoff LC IMPLEMENTED >/dev/null; pass_all self
  A handoff LC CODE_DONE >/dev/null
  A knowledge-done LC not_applicable >/dev/null
  write_report '' '## Amendments' 'Amendment 001 added extra.txt.' '' '## Reopen History' 'Reopened once after DONE to add a helper.'
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null; A validate LC >/dev/null
  echo "lifecycle: reopen with an authorized plan amendment passed"
}

# The real wrapper end to end with a stub `codex`: scripts/worker-run.sh
# refuses to start over an unattributed change, attests every worker window
# (including a failed one), and a wrapper-run worker's changes chain cleanly to
# IMPLEMENTED.
scenario_worker_wrapper() {
  scaffold orchestrated false
  mkdir -p "$base/bin"
  cat > "$base/bin/codex" <<'STUB'
#!/bin/sh
: > "${FAKE_CODEX_MARK:-/dev/null}"
cat > /dev/null
if [ -n "${FAKE_CODEX_EDIT_FILE:-}" ]; then printf '%s\n' "$FAKE_CODEX_EDIT_LINE" >> "$FAKE_CODEX_EDIT_FILE"; fi
if [ -n "${FAKE_CODEX_PHASE:-}" ]; then
  ef=''; [ "$FAKE_CODEX_PHASE" = RED ] && ef='expected_failure: TestImpl fails: lookup is not implemented in impl.txt yet'
  printf 'command: go test ./...\ntarget: impl.txt,impl_test.txt\n%s\n' "$ef" | ./scripts/agent.sh worker-evidence LC "$FAKE_CODEX_PHASE" "$FAKE_CODEX_RESULT" >/dev/null
fi
exit "${FAKE_CODEX_EXIT:-0}"
STUB
  chmod +x "$base/bin/codex"; printf 'implement the bounded change\n' > "$base/prompt.txt"
  wr() { ph=$1; shift; env "$@" PATH="$base/bin:$PATH" sh ./scripts/worker-run.sh LC "$ph" --network not-required --prompt-file "$base/prompt.txt"; }
  printf 'orchestrator edit\n' >> impl.txt
  expect_fail "wrapper started a worker over an orchestrator edit" wr RED FAKE_CODEX_MARK="$base/ran"
  [ ! -e "$base/ran" ] || { echo "FAIL: codex was invoked despite the unattributed change" >&2; exit 1; }
  git checkout -q -- impl.txt
  wr RED FAKE_CODEX_EDIT_FILE=impl_test.txt FAKE_CODEX_EDIT_LINE='test: lookup returns the stored value' FAKE_CODEX_PHASE=RED FAKE_CODEX_RESULT=fail >/dev/null
  grep -q '^exit_status: "0"' .agents/runs/LC/worker-evidence/WINDOW-1.yaml
  expect_fail "a failing worker run was reported as success" wr GREEN FAKE_CODEX_EDIT_FILE=impl.txt FAKE_CODEX_EDIT_LINE='impl: partial work' FAKE_CODEX_EXIT=3
  grep -q '^exit_status: "3"' .agents/runs/LC/worker-evidence/WINDOW-2.yaml       # a failed worker's partial edits are attested history
  A window-open LC >/dev/null                                                      # so the tree is still the last attested one
  wr GREEN FAKE_CODEX_EDIT_FILE=impl.txt FAKE_CODEX_EDIT_LINE='impl: lookup returns the stored value' FAKE_CODEX_PHASE=GREEN FAKE_CODEX_RESULT=pass >/dev/null
  A handoff LC IMPLEMENTED >/dev/null
  pass_all self; A handoff LC CODE_DONE >/dev/null
  A verify-gates LC >/dev/null
  echo "lifecycle: worker-run.sh wrapper attestation passed"
}

# Hardening found by independent review: stray run files are caught although runs are gitignored, one
# amendment authorizes one refreeze, a worker cannot reopen implementation, gates bind the pipeline,
# reports carry exactly one verdict, and a forged terminal state cannot be cleaned up.
scenario_hardening() {
  scaffold orchestrated true no TRIVIAL
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  for f in QA_PLAN.md REVIEW.md scratch-notes.md; do
    printf '# stray\n' > ".agents/runs/LC/$f"
    tc_expect_msg "stray $f passed verify-scope although runs are gitignored" 'unexpected run artifact' A verify-scope LC
    expect_fail "stray $f reached a gate" gate_pass independent_verifier VERIFY
    expect_fail "stray $f reached CODE_DONE" A handoff LC CODE_DONE
    rm ".agents/runs/LC/$f"
  done
  # exactly one verdict per report
  printf '# VERIFY\n\nVerdict: PASS\n\nlater\n\nVerdict: FAIL\n' > .agents/runs/LC/VERIFY.md
  tc_expect_msg "a report with two verdicts was recorded" "exactly one 'Verdict:'" sh -c "printf 'summary: ran the full verification command set on the whole tree\n' | AGENT_ROLE=independent_verifier ./scripts/agent.sh gate LC VERIFY pass"
  # a worker cannot reopen implementation after a finding
  gate_fail independent_verifier VERIFY impl.txt
  tc_expect_msg "a worker reopened implementation" 'only the Orchestrator' AS implementation_worker handoff LC IMPLEMENTING
  A handoff LC IMPLEMENTING >/dev/null
  worker FIX pass impl.txt 'impl: first fix'; A handoff LC IMPLEMENTED >/dev/null
  # amendments: one per refreeze, plain names only, and each must change something
  mkdir -p .agents/runs/LC/amendments; printf '# a1\n' > .agents/runs/LC/amendments/001.md
  tc_expect_msg "a path traversal amendment name was accepted" 'invalid amendment name' A refreeze LC ../TASK.md
  tc_expect_msg "a no-op refreeze was accepted" 'changes nothing' A refreeze LC 001.md
  printf 'amended\n' >> .agents/runs/LC/PLAN.md; A refreeze LC 001.md >/dev/null
  printf 'amended again\n' >> .agents/runs/LC/PLAN.md
  tc_expect_msg "an amendment file was reused" 'already used' A refreeze LC 001.md
  # a forged terminal state is not a terminal outcome
  cp .agents/runs/LC/RUN.yaml "$base/run.forge"
  sed 's/^  state: ".*"/  state: "BLOCKED"/' "$base/run.forge" > .agents/runs/LC/RUN.yaml
  expect_fail "cleanup of a hand-forged BLOCKED run" A cleanup LC
  [ -d .agents/runs/LC ]
  cp "$base/run.forge" .agents/runs/LC/RUN.yaml
  echo "lifecycle: review-found hardening passed"
}

# --- task-source contract -----------------------------------------------------
# Failure scenario: a run freezes its task file, and at completion the file
# legitimately moves todo -> in-progress -> done and its Status changes.
# `freshness` reports the moved file as stale, but if `publish-completion-report`
# never checks freshness and re-hashes the whole file after the adapter appends
# the report, *any* edit made before publish is absorbed and re-baselined.
# A run freezes only the task contract; the Status value and the published
# report block are bookkeeping;
# the revision is written by freeze/refreeze alone; the location changes only
# through `task-source-relocate`; and path and revision are sealed in the
# lifecycle ledger.

# The full completion sequence (move, Status change, relocation, publish) in
# both topologies, with explicit bookkeeping semantics.
scenario_task_contract_bookkeeping() {
  topo=$1; tc_scaffold_done "$topo"; frozen=$(rv task_source revision)
  mkdir -p tasks/done; git mv tasks/in-progress/LC.md tasks/done/LC.md; tc_status tasks/done/LC.md done
  tc_expect_msg "a moved task source was accepted without being relocated" 'task-source-relocate' A freshness LC
  expect_fail "knowledge-done accepted a moved, unrelocated task source" A knowledge-done LC not_applicable
  A task-source-relocate LC tasks/done/LC.md >/dev/null
  expect_state task_source path tasks/done/LC.md; expect_state task_source revision "$frozen"
  A freshness LC >/dev/null; A verify-seal LC >/dev/null                # the move and the Status change are bookkeeping
  finish_done
  [ "$(rv task_source revision)" = "$frozen" ] || { echo "FAIL: publish re-baselined the frozen task contract" >&2; exit 1; }
  grep -Fq '<!-- COMPLETION-REPORT:BEGIN:LC -->' tasks/done/LC.md
  A freshness LC >/dev/null; A verify-seal LC >/dev/null; A verify-completion-report LC >/dev/null
  A delivery-check LC >/dev/null; A validate LC >/dev/null
  tc_expect_msg "relocation accepted after the completion report was published" 'receipt binds' A task-source-relocate LC tasks/elsewhere.md
  cp tasks/done/LC.md "$base/published.md"
  printf '%s\n' '- a requirement added after publication' >> tasks/done/LC.md
  tc_expect_msg "a contract edit after the END marker was accepted" 'frozen task contract changed' A freshness LC
  cp "$base/published.md" tasks/done/LC.md; A freshness LC >/dev/null
  echo "lifecycle: task-source contract bookkeeping ($topo) passed"
}

# A contract edit made in place before publish is never absorbed.
scenario_task_contract_edit() {
  topo=$1; tc_scaffold_done "$topo"; frozen=$(rv task_source revision)
  printf '%s\n' '- a requirement added after freeze' >> tasks/in-progress/LC.md
  tc_expect_msg "an edited task contract passed freshness" 'frozen task contract changed' A freshness LC
  tc_expect_msg "knowledge-done accepted an edited task contract" 'frozen task contract changed' A knowledge-done LC not_applicable
  expect_state execution knowledge_state not_started
  write_report
  tc_expect_msg "publish accepted an edited task contract" 'frozen task contract changed' A publish-completion-report LC markdown
  expect_state completion_report published false; expect_state task_source revision "$frozen"
  if grep -Fq 'COMPLETION-REPORT:BEGIN' tasks/in-progress/LC.md; then echo "FAIL: the adapter ran against an edited task contract" >&2; exit 1; fi
  tc_expect_msg "DONE accepted an edited task contract" 'frozen task contract changed' A handoff LC DONE
  echo "lifecycle: task-source contract in-place edit ($topo) rejected"
}

# The same move with a contract change smuggled in alongside it, and
# hand edits of the sealed path and revision.
scenario_task_contract_laundering() {
  tc_scaffold_done standalone; frozen=$(rv task_source revision)
  mkdir -p tasks/done; git mv tasks/in-progress/LC.md tasks/done/LC.md; tc_status tasks/done/LC.md done
  printf '%s\n' '- a requirement smuggled in with the move' >> tasks/done/LC.md
  tc_expect_msg "a relocation absorbed an edited contract" 'differs from the frozen contract' A task-source-relocate LC tasks/done/LC.md
  expect_state task_source path tasks/in-progress/LC.md; expect_state task_source revision "$frozen"
  cp .agents/runs/LC/RUN.yaml "$base/RUN.saved"
  awk '/^  path: tasks\/in-progress\/LC.md$/ { print "  path: tasks/done/LC.md"; next } { print }' "$base/RUN.saved" > .agents/runs/LC/RUN.yaml
  tc_expect_msg "a hand-edited task source path was accepted" 'edited by hand' A verify-seal LC
  expect_fail "knowledge-done ran over a hand-edited task source path" A knowledge-done LC not_applicable
  cp "$base/RUN.saved" .agents/runs/LC/RUN.yaml; A verify-seal LC >/dev/null
  awk '/^  revision: / { print "  revision: \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""; next } { print }' "$base/RUN.saved" > .agents/runs/LC/RUN.yaml
  tc_expect_msg "a hand-edited task revision was accepted" 'edited by hand' A verify-seal LC
  cp "$base/RUN.saved" .agents/runs/LC/RUN.yaml; A verify-seal LC >/dev/null
  echo "lifecycle: task-source contract laundering rejected"
}

# task-source-relocate is a move, validated before it changes anything.
scenario_task_contract_relocate() {
  tc_scaffold_done standalone
  cp tasks/in-progress/LC.md tasks/copy.md
  tc_expect_msg "a copy was accepted as a move" 'not a copy' A task-source-relocate LC tasks/copy.md
  rm -f tasks/copy.md
  tc_expect_msg "the recorded path was accepted as a relocation" 'already recorded' A task-source-relocate LC tasks/in-progress/LC.md
  tc_expect_msg "an absolute path was accepted" 'invalid task source path' A task-source-relocate LC /etc/hosts
  tc_expect_msg "a parent-directory path was accepted" 'invalid task source path' A task-source-relocate LC tasks/../LC.md
  git mv tasks/in-progress/LC.md tasks/moved.md
  tc_expect_msg "a missing target was accepted" 'missing or non-regular' A task-source-relocate LC tasks/nowhere.md
  ln -s moved.md tasks/link.md
  tc_expect_msg "a symlink target was accepted" 'symlink' A task-source-relocate LC tasks/link.md
  tc_expect_msg "an independent reviewer relocated the task source" 'denied' AS independent_reviewer task-source-relocate LC tasks/moved.md
  tc_expect_msg "an independent verifier relocated the task source" 'denied' AS independent_verifier task-source-relocate LC tasks/moved.md
  tc_expect_msg "an implementation worker relocated the task source" 'denied' AS implementation_worker task-source-relocate LC tasks/moved.md
  A task-source-relocate LC tasks/moved.md >/dev/null; expect_state task_source path tasks/moved.md
  A freshness LC >/dev/null; A verify-seal LC >/dev/null
  echo "lifecycle: task-source relocation checks passed"
}

# An adapter that touches anything but the report block cannot re-baseline or
# change the contract: the task source is restored and nothing is recorded.
scenario_task_contract_adapter() {
  tc_scaffold_done standalone; frozen=$(rv task_source revision)
  cp tasks/in-progress/LC.md "$base/pre-publish.md"
  A knowledge-done LC not_applicable >/dev/null; write_report
  printf '%s\n' '#!/bin/sh' 'set -eu' 'root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)' \
    'path=$(sed -n "s/^  path: //p" "$root/.agents/runs/$2/RUN.yaml" | head -1)' \
    'case "$1" in publish) printf "%s\n" "- a requirement the adapter added" >> "$root/$path"; printf "%s#feedface\n" "$path" ;; verify) exit 0 ;; esac' \
    > .agents/task-integrations/evil.sh
  chmod +x .agents/task-integrations/evil.sh
  tc_expect_msg "an adapter that changed the contract was accepted" 'outside the completion-report block' A publish-completion-report LC evil
  cmp -s tasks/in-progress/LC.md "$base/pre-publish.md" || { echo "FAIL: the task source was not restored byte for byte" >&2; exit 1; }
  expect_state completion_report published false; expect_state task_source revision "$frozen"
  A freshness LC >/dev/null
  rm -f .agents/task-integrations/evil.sh
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
  expect_state task_source revision "$frozen"
  echo "lifecycle: task-source contract adapter confinement passed"
}

# What the projection treats as bookkeeping (accepted) and as contract (rejected).
scenario_task_contract_projection() {
  scaffold standalone false yes; f=tasks/in-progress/LC.md; cp "$f" "$base/orig.md"
  ok() { cp "$base/orig.md" "$f"; "$@"; A freshness LC >/dev/null 2>&1 || { echo "FAIL: bookkeeping change rejected: $*" >&2; exit 1; }; }
  bad() { d=$1; shift; cp "$base/orig.md" "$f"; "$@"; if A freshness LC >/dev/null 2>&1; then echo "FAIL: contract change accepted: $d" >&2; exit 1; fi; }
  block() { printf '\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:%s -->\nreport\n<!-- COMPLETION-REPORT:END:%s -->\n' "$1" "$1" >> "$f"; }
  A freshness LC >/dev/null
  ok tc_status "$f" in-progress
  # Whatever the Status value, it is never part of the contract: a value that disagrees with the
  # lifecycle folder is refused as a status mismatch (not a contract change), and synchronizing it
  # leaves the frozen contract untouched.
  for v in done 'anything at all, even several words'; do
    cp "$base/orig.md" "$f"; tc_status "$f" "$v"
    tc_expect_msg "a Status value was read as contract" 'task-source-status' A freshness LC
    A task-source-status LC >/dev/null; A freshness LC >/dev/null
  done
  ok sh -c "printf '\n\n\n' >> '$f'"
  ok block LC
  bad "text after the END marker" sh -c "printf '\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:LC -->\nr\n<!-- COMPLETION-REPORT:END:LC -->\n- extra requirement\n' >> '$f'"
  bad "a second report block" sh -c "printf '\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:LC -->\nr\n<!-- COMPLETION-REPORT:END:LC -->\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:LC -->\nr2\n<!-- COMPLETION-REPORT:END:LC -->\n' >> '$f'"
  bad "a block for another task" block OTHER
  bad "a completion-report heading without markers" sh -c "printf '\n## Completion Report\n\nnotes\n' >> '$f'"
  bad "a block that is never closed" sh -c "printf '\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:LC -->\nr\n' >> '$f'"
  bad "an edited requirement" sh -c "sed 's/documented default/other default/' '$f' > '$f.new' && mv '$f.new' '$f'"
  bad "a removed requirement" sh -c "grep -v 'documented default' '$f' > '$f.new'; mv '$f.new' '$f'"
  bad "a body line that only looks like Status" sh -c "printf 'Status: done\n' >> '$f'"
  cp "$base/orig.md" "$f"; A freshness LC >/dev/null
  echo "lifecycle: task-source contract projection passed"
}

# A finding's fix_scope is a comma-separated list; entries written with spaces after the
# commas are the same paths, and a path that is not listed is still refused.
scenario_fix_scope_format() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle REVIEW 'impl.txt, impl_test.txt'; A handoff LC IMPLEMENTING >/dev/null
  worker FIX pass impl_test.txt 'test: empty key returns the documented default'      # the second listed entry
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle QA impl.txt; A handoff LC IMPLEMENTING >/dev/null
  worker FIX pass impl_test.txt 'test: a path that the finding did not list'
  tc_expect_msg "a fix outside the listed fix_scope reached IMPLEMENTED" "outside the finding's fix_scope" A handoff LC IMPLEMENTED
  echo "lifecycle: fix_scope entry format passed"
}

# An amendment that changes any frozen artifact (here only the QA plan) starts a fresh
# fix budget, and the findings recorded against the previous contract stop holding the tree.
scenario_amendment_fresh_budget() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle REVIEW impl.txt; A handoff LC IMPLEMENTING >/dev/null
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: the QA plan misstated a scenario\n' > .agents/runs/LC/amendments/001.md
  printf -- '- QA-2 (AC-1): clarified scenario\n' >> .agents/runs/LC/QA_PLAN.md
  A refreeze LC 001.md >/dev/null
  expect_state handoff state IMPLEMENTING
  A handoff LC IMPLEMENTED >/dev/null                                             # the evidence is still valid; the old finding no longer binds
  gate_fail full_lifecycle QA impl.txt; A handoff LC IMPLEMENTING >/dev/null      # finding #1 of the new contract
  worker FIX pass impl.txt 'impl: first attempt after the amendment'; A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle VERIFY impl.txt; A handoff LC IMPLEMENTING >/dev/null  # finding #2: still inside the budget
  worker FIX pass impl.txt 'impl: second attempt after the amendment'; A handoff LC IMPLEMENTED >/dev/null
  gate_fail full_lifecycle REVIEW impl.txt                                        # finding #3: the fresh budget is spent
  expect_fail "a third fix was allowed after the amendment" A handoff LC IMPLEMENTING
  echo "lifecycle: amendment fresh fix budget passed"
}

# The task source's Status line must agree with its lifecycle folder; it is synchronized by
# `task-source-status`, which changes only that line and is never a way to edit the contract.
scenario_task_source_status() {
  scaffold orchestrated true yes
  frozen=$(rv task_source revision)
  A freshness LC >/dev/null
  tc_status tasks/in-progress/LC.md todo                                          # the file moved, the Status was left behind
  tc_expect_msg "a stale Status passed freshness" 'task-source-status' A freshness LC
  tc_expect_msg "a stale Status passed a handoff" 'task-source-status' A handoff LC IMPLEMENTING
  tc_expect_msg "a stale Status passed a refreeze" 'task-source-status' A refreeze LC missing.md
  expect_fail "the worker changed the task status" AS implementation_worker task-source-status LC
  expect_fail "a reviewer changed the task status" AS independent_reviewer task-source-status LC
  A task-source-status LC >/dev/null
  grep -Fxq '**Status:** in-progress' tasks/in-progress/LC.md
  expect_state task_source revision "$frozen"; A freshness LC >/dev/null; A verify-seal LC >/dev/null
  A verify-scope LC >/dev/null                                                    # a Status-only change is bookkeeping, not scope drift
  A task-source-status LC | grep -Fq 'already in-progress'
  printf '%s\n' '- a requirement added after freeze' >> tasks/in-progress/LC.md    # the contract itself may not change through this command
  tc_status tasks/in-progress/LC.md todo
  tc_expect_msg "task-source-status absorbed a contract edit" 'frozen task contract would change' A task-source-status LC
  tc_expect_msg "a contract edit hidden behind a stale Status passed" 'task-source-status' A freshness LC
  grep -Fxq '**Status:** todo' tasks/in-progress/LC.md
  echo "lifecycle: task source status synchronization passed"
}

# Moving the task to done/ needs the Status to follow before anything else proceeds; the
# command is refused once the completion report is published, and a source outside the
# lifecycle folders has nothing to synchronize.
scenario_task_source_status_done() {
  tc_scaffold_done orchestrated
  mkdir -p tasks/done; git mv tasks/in-progress/LC.md tasks/done/LC.md           # moved, Status left as in-progress
  A task-source-relocate LC tasks/done/LC.md >/dev/null
  tc_expect_msg "a stale Status in done/ passed freshness" 'task-source-status' A freshness LC
  tc_expect_msg "knowledge-done accepted a stale Status" 'task-source-status' A knowledge-done LC not_applicable
  A task-source-status LC >/dev/null
  grep -Fxq '**Status:** done' tasks/done/LC.md
  finish_done; A delivery-check LC >/dev/null; A validate LC >/dev/null
  tc_expect_msg "the status changed after the report was published" 'receipt binds' A task-source-status LC
  scaffold orchestrated false                                                    # tasks/LC.md: not in a lifecycle folder
  tc_expect_msg "a source outside the lifecycle folders was synchronized" 'not under a lifecycle folder' A task-source-status LC
  A freshness LC >/dev/null
  echo "lifecycle: task source status in done/ passed"
}

# Execution policy end to end through the real wrappers with a stub `codex`:
# scripts/worker-run.sh asks `agent.sh decide` for the attempt's one resolved decision
# and translates exactly that into codex arguments; escalation, retry bound, override
# rejection and the context budget all act before/around the (stub) model call.
scenario_execution_policy() {
  scaffold orchestrated false                                                     # COMPLEX: terra / high / 98304 bytes
  mkdir -p "$base/bin"; rm -f "$base/args" "$base/stdin" "$base/ran"
  cat > "$base/bin/codex" <<'STUB'
#!/bin/sh
: > "${FAKE_CODEX_MARK:-/dev/null}"
printf '%s\n' "$*" >> "$FAKE_CODEX_ARGS"; cat > "$FAKE_CODEX_STDIN"
exit "${FAKE_CODEX_EXIT:-0}"
STUB
  chmod +x "$base/bin/codex"; printf 'implement the bounded change\n' > "$base/prompt.txt"
  wp() { ph=$1; shift; env FAKE_CODEX_ARGS="$base/args" FAKE_CODEX_STDIN="$base/stdin" FAKE_CODEX_MARK="$base/ran" ${EXTRA_ENV:-} PATH="$base/bin:$PATH" sh ./scripts/worker-run.sh LC "$ph" --network not-required --prompt-file "${PF:-$base/prompt.txt}" "$@"; }
  wpx() { EXTRA_ENV=FAKE_CODEX_EXIT=3; wpx_rc=0; wp "$@" || wpx_rc=$?; EXTRA_ENV=; return "$wpx_rc"; }   # a worker that exits 3
  wpf() { PF=$1; shift; wpf_rc=0; wp "$@" || wpf_rc=$?; PF=; return "$wpf_rc"; }                        # a different prompt file
  last_args() { tail -1 "$base/args"; }
  dec() { sed -n "s/^$2=//p" ".agents/runs/LC/decisions/$1.decision"; }
  # first attempt: the decision, not ~/.codex/config.toml, picks model and effort
  expect_fail "a failing worker was reported as success" wpx GREEN
  case "$(last_args)" in *"--model gpt-5.6-terra"*"model_reasoning_effort=high"*) ;; *) echo "FAIL: codex did not receive the resolved model/effort: $(last_args)" >&2; exit 1 ;; esac
  [ "$(dec 0-GREEN-1 outcome)" = failure ] && [ "$(dec 0-GREEN-1 exit_status)" = 3 ] && [ "$(dec 0-GREEN-1 attempt)" = 1 ]
  head -1 "$base/stdin" | grep -q '^=== STABLE PREFIX'; grep -q '=== DYNAMIC' "$base/stdin"; grep -q 'implement the bounded change' "$base/stdin"
  sed '/^=== DYNAMIC/,$d' "$base/stdin" > "$base/prefix1"
  # a stated reasoning failure escalates effort, and the change is recorded with its reason
  expect_fail "still failing" wpx GREEN --failure INSUFFICIENT_REASONING
  case "$(last_args)" in *"model_reasoning_effort=xhigh"*) ;; *) echo "FAIL: escalation did not reach codex: $(last_args)" >&2; exit 1 ;; esac
  [ "$(dec 0-GREEN-2 escalation)" = ESCALATED_REASONING ] && [ "$(dec 0-GREEN-2 attempt)" = 2 ] && [ "$(dec 0-GREEN-2 esc_events)" = 1 ]
  sed '/^=== DYNAMIC/,$d' "$base/stdin" > "$base/prefix2"; cmp -s "$base/prefix1" "$base/prefix2"      # stable prefix byte-identical across attempts
  expect_fail "still failing" wpx GREEN --failure INSUFFICIENT_REASONING
  case "$(last_args)" in *"model_reasoning_effort=max"*) ;; *) echo "FAIL: second escalation: $(last_args)" >&2; exit 1 ;; esac
  # the bound: 1 + max_bounded_fix_attempts attempts, then a refusal that never reaches codex
  rm -f "$base/ran"; expect_fail "a fourth attempt ran" wp GREEN --failure INSUFFICIENT_REASONING
  [ ! -e "$base/ran" ] || { echo "FAIL: codex ran past the retry limit" >&2; exit 1; }
  ls .agents/runs/LC/decisions | grep -c '^0-GREEN-' | grep -qx 3
  # overrides: hard-forbidden and unsupported values are refused before codex; a valid one wins
  expect_fail "ultra effort was accepted" wp RED --effort ultra
  expect_fail "an unknown model was accepted" wp RED --model no-such-model
  [ ! -e "$base/ran" ] || { echo "FAIL: codex ran for a rejected override" >&2; exit 1; }
  [ ! -e ".agents/runs/LC/decisions/0-RED-1.decision" ] || { echo "FAIL: a rejected override left a decision" >&2; exit 1; }
  wp RED --model gpt-5.6-sol --effort low >/dev/null
  case "$(last_args)" in *"--model gpt-5.6-sol"*"model_reasoning_effort=low"*) ;; *) echo "FAIL: override did not reach codex: $(last_args)" >&2; exit 1 ;; esac
  [ "$(dec 0-RED-1 overrides)" = model,effort ]
  # the context budget: the task prompt is never silently truncated; a failure log is tail-truncated
  head -c 100000 /dev/zero | tr '\0' 'x' > "$base/big.txt"; rm -f "$base/ran"
  expect_fail "an over-budget prompt was sent" wpf "$base/big.txt" REFACTOR
  [ ! -e "$base/ran" ] && [ "$(dec 0-REFACTOR-1 aborted)" = context_budget ]
  head -c 300000 /dev/zero | tr '\0' 'y' > "$base/log.txt"
  wpf "$base/big.txt" REFACTOR --failure CONTEXT_MISSING --failure-file "$base/log.txt" >/dev/null
  [ "$(dec 0-REFACTOR-2 context_bytes)" = 196608 ] && [ "$(dec 0-REFACTOR-2 context_truncated)" = failure_log ]
  [ "$(wc -c < "$base/stdin")" -le $((196608 + $(wc -c < "$base/prefix1") + 200)) ]
  # the decision is control metadata: the run still validates
  if v=$(A validate LC 2>&1); then :; else case "$v" in *"unexpected run artifact"*) echo "FAIL: decisions/ is not a known control artifact: $v" >&2; exit 1 ;; esac; fi
  echo "lifecycle: execution policy end to end passed"
}

# LC_LIB=1 (scripts/oversight-test.sh sources this file) defines the helpers and runs no scenario.
if [ -z "${LC_LIB:-}" ]; then
run_sc scenario_standalone claude
run_sc scenario_standalone codex short
run_sc scenario_independence
run_sc scenario_orchestrated_loop
run_sc scenario_attribution
run_sc scenario_worker_wrapper
run_sc scenario_execution_policy
run_sc scenario_bounded_fix
run_sc scenario_fix_scope_format
run_sc scenario_amendment_fresh_budget
run_sc scenario_terminal
run_sc scenario_pipeline_trivial
run_sc scenario_pipeline_standard
run_sc scenario_classification
run_sc scenario_amend_plan_change
run_sc scenario_hardening
run_sc scenario_task_contract_bookkeeping standalone
run_sc scenario_task_contract_bookkeeping orchestrated
run_sc scenario_task_contract_edit standalone
run_sc scenario_task_contract_edit orchestrated
run_sc scenario_task_contract_laundering
run_sc scenario_task_contract_relocate
run_sc scenario_task_contract_adapter
run_sc scenario_task_contract_projection
run_sc scenario_task_source_status
run_sc scenario_task_source_status_done
echo 'agent lifecycle tests passed'
fi

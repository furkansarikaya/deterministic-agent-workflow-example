#!/bin/sh
# Regression tests for the lifecycle-gate hardening in scripts/agent.sh:
# REVIEW/QA gates bound to the exact application tree, mutation ownership
# under orchestrated topology, independence enforcement, bounded fix loop,
# the hash-chained lifecycle ledger (manual-rewind detection) and the scripted
# `amend` reopen. Run via `scripts/agent.sh test`, or directly.
#
# Each scenario builds a throwaway git repository with a `lifecycle_gates` run
# and drives the real agent.sh. Roles are the generic control-plane roles
# (full_lifecycle, implementation_worker, independent_reviewer,
# independent_verifier); the control plane has no vendor concept, so "Claude
# standalone" and "Codex standalone" are the same full_lifecycle scenario, and
# the orchestrated scenarios below map an orchestrator that also reviews to
# full_lifecycle and the delegated implementer to implementation_worker.
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
gate_pass() { AS "$1" gate LC "$2" pass <<EOF
summary: ran the full verification command set and inspected the whole diff of the current tree
EOF
}
gate_fail() { AS "$1" gate LC "$2" fail <<EOF
summary: ran the full verification command set and inspected the whole diff of the current tree
findings: lookup in impl.txt returns the wrong value for an empty key in the reviewed tree
fix_scope: $3
fix_instruction: make lookup return the documented default for an empty key and cover it with a test
EOF
}
amend_as() { printf 'reason: %s\nfix_scope: %s\nfix_instruction: %s\nauthorized_by: %s\n' "$2" "$3" "$4" "$5" | AGENT_ROLE=$1 ./scripts/agent.sh amend LC; }
write_report() {
  printf '%s\n' '# Completion Report: LC' '' '## Implementation Summary' 'impl.txt and impl_test.txt changed under the lifecycle gates.' '' \
    '## TDD Evidence' 'RED then GREEN recorded by the expected implementation owner.' '' '## Verification' 'All gates passed on the final tree.' '' \
    '## Review Result' 'Approved on the final tree.' '' '## Known Limitations / Follow-up' 'None.' "$@" > .agents/runs/LC/COMPLETION_REPORT.md
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
    A handoff LC VERIFIED >/dev/null
    gate_pass independent_reviewer REVIEW; A handoff LC REVIEWED >/dev/null
    gate_pass independent_verifier QA; A handoff LC CODE_DONE >/dev/null
  else
    solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
    A handoff LC VERIFIED >/dev/null
    gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
    gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  fi
}
tc_scaffold_done() { # topology — a contract-scheme fixture at CODE_DONE
  if [ "$1" = orchestrated ]; then scaffold orchestrated true yes yes; else scaffold standalone false yes yes; fi
  tc_to_code_done "$1"
}
tc_expect_msg() { # description pattern command... — the command must fail *for this reason*
  d=$1 pat=$2; shift 2
  if tm_out=$("$@" 2>&1); then echo "FAIL: $d (command succeeded)" >&2; exit 1; fi
  printf '%s' "$tm_out" | grep -Fq -- "$pat" || { echo "FAIL: $d (rejected for another reason: $(printf '%s' "$tm_out" | tail -1))" >&2; exit 1; }
}

# scaffold <topology> <independent:true|false> [gates:yes|no] [contract:yes|no]
# — leaves the fixture at handoff IMPLEMENTING (frozen), cwd inside it. With
# contract=yes the run carries `task_source.revision_scheme: contract` and its
# task file follows the todo/in-progress/done convention: committed under
# tasks/todo/, then moved (uncommitted, before baseline) to tasks/in-progress/,
# which is how a task file is normally started.
scaffold() {
  topo=$1 indep=$2 gates=${3:-yes} contract=${4:-no}
  tpath=tasks/LC.md; [ "$contract" = yes ] && tpath=tasks/in-progress/LC.md
  n_fx=$((n_fx + 1)); fx=$base/fx$n_fx
  mkdir -p "$fx/.agents/runs/LC/review" "$fx/.agents/modes" "$fx/.agents/task-integrations" "$fx/scripts" "$fx/tasks"
  cp "$root/scripts/agent.sh" "$root/scripts/worker-run.sh" "$fx/scripts/"; cp "$root/.agents/config.yaml" "$fx/.agents/"
  cp "$root/.agents/task-integrations/markdown.sh" "$fx/.agents/task-integrations/"; chmod +x "$fx/.agents/task-integrations/markdown.sh"
  for m in "$root/.agents/modes/"*.yaml; do
    sed "s/independent: true/independent: $indep/; s/independent_verifier: true/independent_verifier: $indep/" "$m" > "$fx/.agents/modes/$(basename "$m")"
  done
  printf 'LC\n' > "$fx/.agents/ACTIVE_RUN"
  printf '# Task: LC\n\n## Acceptance criteria\n\n- AC-1: lookup behavior\n' > "$fx/.agents/runs/LC/TASK.md"
  printf '# Evidence\n' > "$fx/.agents/runs/LC/EVIDENCE.md"
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '---' '# Plan' > "$fx/.agents/runs/LC/PLAN.md"
  {
    printf '%s\n' 'repository:' '  base_sha: PENDING' 'task_source:' '  type: local_markdown' "  path: $tpath" '  revision: PENDING' \
      'execution:' '  mode: deterministic' '  profile: core' '  state: PLANNING' '  knowledge_state: not_started' "  topology: $topo" \
      'freeze:' '  task_sha256: PENDING' '  evidence_sha256: PENDING' '  plan_sha256: PENDING' '  policy_sha256: PENDING' \
      'baseline:' '  status: pending' \
      'handoff:' '  state: PLANNED' '  verification_patch_sha256: PENDING' '  review_patch_sha256: PENDING' '  code_done_patch_sha256: PENDING' \
      'worker_evidence:' '  required: true' 'tdd:' '  required: true' \
      'completion_report:' '  required: true' '  adapter: PENDING' '  published: false' '  receipt: PENDING'
    [ "$gates" = yes ] && printf '%s\n' 'lifecycle_gates:' '  required: true'
    true
  } > "$fx/.agents/runs/LC/RUN.yaml"
  if [ "$contract" = yes ]; then
    awk '{ print } /^  revision: PENDING$/ { print "  revision_scheme: contract" }' "$fx/.agents/runs/LC/RUN.yaml" > "$fx/.agents/runs/LC/RUN.yaml.new" && mv "$fx/.agents/runs/LC/RUN.yaml.new" "$fx/.agents/runs/LC/RUN.yaml"
  fi
  printf '# review\n' > "$fx/.agents/runs/LC/review/code-review.md"; printf '# verification\n' > "$fx/.agents/runs/LC/review/verification.md"; printf '# result\n' > "$fx/.agents/runs/LC/RESULT.md"
  cd "$fx"
  git init -q -b main; git config user.email lifecycle@example.invalid; git config user.name fixture
  : > impl.txt; : > impl_test.txt
  if [ "$contract" = yes ]; then
    mkdir -p tasks/todo; printf '%s\n' '# LC task' '' '**Status:** todo' '' '## Requirements' '' '- lookup returns the documented default for an empty key' > tasks/todo/LC.md
  else
    printf '# LC task\n' > tasks/LC.md
  fi
  git add -- .agents scripts tasks impl.txt impl_test.txt; git commit -qm baseline
  if [ "$contract" = yes ]; then mkdir -p tasks/in-progress; git mv tasks/todo/LC.md tasks/in-progress/LC.md; tc_status tasks/in-progress/LC.md in-progress; fi
  A baseline LC >/dev/null; printf 'discovered\n' >> .agents/runs/LC/EVIDENCE.md; printf 'planned\n' >> .agents/runs/LC/PLAN.md
  A freeze LC >/dev/null; A handoff LC IMPLEMENTING >/dev/null
}

# --- scenarios ---------------------------------------------------------------

# LC_ONLY=<substring> runs only the scenarios whose function name contains it.
run_sc() { if [ -z "${LC_ONLY:-}" ] || printf '%s' "$1" | grep -q -- "$LC_ONLY"; then "$@"; fi; }

# Standalone: full_lifecycle owns everything and may change application code
# and tests directly at any point, including after review; independence is not
# required by this run's policy. The same scenario is what "Claude standalone"
# and "Codex standalone" both are — the control plane is vendor-neutral.
scenario_standalone() {
  scaffold standalone false; label=$1 full=${2:-full}
  solo RED fail impl_test.txt "test ($label): lookup returns the stored value"
  solo GREEN pass impl.txt "impl ($label): lookup returns the stored value"
  A handoff LC VERIFIED >/dev/null
  expect_fail "REVIEWED without a review gate" A handoff LC REVIEWED
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null            # independent=false: self-review is enough
  if [ "$full" = short ]; then
    gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null; finish_done; A delivery-check LC >/dev/null
    echo "lifecycle: standalone ($label) passed"; return 0
  fi
  # a change after review (standalone may make it) voids review; nothing carries over
  printf 'late tweak\n' >> impl.txt
  expect_fail "stale review accepted by verify-handoff" A verify-handoff LC
  expect_fail "QA recorded on a tree changed since REVIEWED" gate_pass full_lifecycle QA
  A handoff LC VERIFIED >/dev/null
  expect_fail "REVIEWED using the review pass for the older tree" A handoff LC REVIEWED
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass full_lifecycle QA
  printf 'another tweak\n' >> impl.txt                                          # a change after QA voids QA and review
  expect_fail "CODE_DONE on a QA pass for an older tree" A handoff LC CODE_DONE
  A handoff LC VERIFIED >/dev/null
  expect_fail "REVIEWED on stale passes" A handoff LC REVIEWED
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  expect_fail "CODE_DONE without a QA pass on this tree" A handoff LC CODE_DONE
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  finish_done
  A delivery-check LC >/dev/null; A validate LC >/dev/null; A verify-gates LC >/dev/null
  echo "lifecycle: standalone ($label) passed"
}

# Standalone with review.independent / verification.independent_verifier true:
# self-authored gates never satisfy them; independent roles do; and the two
# independent roles are read-only observers.
scenario_independence() {
  scaffold standalone true
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC VERIFIED >/dev/null
  expect_fail "self-review satisfied review.independent" gate_pass full_lifecycle REVIEW
  expect_fail "QA role recorded a REVIEW gate" gate_pass independent_verifier REVIEW
  gate_pass independent_reviewer REVIEW
  rf=$(ls .agents/runs/LC/gates/*-REVIEW.yaml); cp "$rf" "$base/review.bak"
  sed 's/^role: .*/role: "full_lifecycle"/' "$base/review.bak" > "$rf"
  expect_fail "hand-relabelled self-review counted as independent" A handoff LC REVIEWED
  cp "$base/review.bak" "$rf"
  A handoff LC REVIEWED >/dev/null
  expect_fail "self-verification satisfied verification.independent_verifier" gate_pass full_lifecycle QA
  expect_fail "reviewer role recorded a QA gate" gate_pass independent_reviewer QA
  gate_pass independent_verifier QA
  qf=$(ls .agents/runs/LC/gates/*-QA.yaml); cp "$qf" "$base/qa.bak"
  sed 's/^role: .*/role: "full_lifecycle"/' "$base/qa.bak" > "$qf"
  expect_fail "hand-relabelled self-QA counted as independent" A handoff LC CODE_DONE
  cp "$base/qa.bak" "$qf"
  A handoff LC CODE_DONE >/dev/null
  # role boundaries
  for r in independent_reviewer independent_verifier; do
    expect_fail "$r moved the lifecycle" AS "$r" handoff LC DONE
    expect_fail "$r froze" AS "$r" freeze LC
    expect_fail "$r reopened a run" AS "$r" amend LC
    expect_fail "$r recorded implementation evidence" sh -c "printf 'command: x\ntarget: impl.txt\n' | AGENT_ROLE=$r ./scripts/agent.sh worker-evidence LC GREEN pass"
    AS "$r" verify-handoff LC >/dev/null
  done
  expect_fail "implementation_worker recorded a gate" gate_pass implementation_worker QA
  finish_done; A delivery-check LC >/dev/null
  for r in independent_reviewer independent_verifier; do AS "$r" validate LC >/dev/null; done
  echo "lifecycle: independence enforcement passed"
}

# The orchestrated topology end to end (one agent orchestrates and reviews, a
# separate implementation_worker writes the code), with the
# sequence: worker implementation -> review FAIL -> worker fix -> review PASS
# -> QA FAIL -> worker fix -> review PASS -> QA PASS -> CODE_DONE -> DONE ->
# reopen -> worker fix -> review -> QA -> CODE_DONE -> DONE.
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
  A handoff LC VERIFIED >/dev/null; expect_state handoff state VERIFIED
  # REVIEW: gate authorship and ordering.
  expect_fail "orchestrator self-review satisfied review.independent" gate_pass full_lifecycle REVIEW
  expect_fail "implementation_worker recorded a gate" gate_pass implementation_worker REVIEW
  expect_fail "QA recorded before review" gate_pass independent_verifier QA
  expect_fail "REVIEWED with no review gate" A handoff LC REVIEWED
  # REVIEW FAIL -> bounded finding/fix contract -> the orchestrator may not fix it.
  gate_fail independent_reviewer REVIEW impl.txt
  expect_fail "a second gate on a tree with an open finding" gate_pass independent_reviewer REVIEW
  expect_fail "REVIEWED with an open finding" A handoff LC REVIEWED
  A handoff LC IMPLEMENTING >/dev/null; expect_state handoff state IMPLEMENTING
  cp impl.txt "$base/impl.saved"; printf 'orchestrator quick fix\n' >> impl.txt
  expect_fail "orchestrator's own fix reached VERIFIED" A handoff LC VERIFIED
  expect_fail "worker window absorbed the orchestrator's fix" A window-open LC
  cp "$base/impl.saved" impl.txt
  A window-open LC >/dev/null                                            # tree is the last attested one again
  worker FIX pass impl.txt 'impl: lookup returns the documented default for an empty key'
  A handoff LC VERIFIED >/dev/null
  gate_pass independent_reviewer REVIEW; A handoff LC REVIEWED >/dev/null
  # QA FAIL -> worker fix -> REVIEW again -> QA again.
  gate_fail independent_verifier QA impl_test.txt
  expect_fail "CODE_DONE with a failing QA" A handoff LC CODE_DONE
  expect_fail "review pass reused after a QA fail on the same tree" A handoff LC REVIEWED
  A handoff LC IMPLEMENTING >/dev/null
  worker FIX pass impl_test.txt 'test: an empty key returns the documented default'
  A handoff LC VERIFIED >/dev/null
  expect_fail "QA recorded before the new review" gate_pass independent_verifier QA
  gate_pass independent_reviewer REVIEW; A handoff LC REVIEWED >/dev/null
  expect_fail "CODE_DONE before the QA re-run" A handoff LC CODE_DONE
  gate_pass independent_verifier QA; A handoff LC CODE_DONE >/dev/null
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
  expect_fail "transition layered on a hand-rewound state" A handoff LC VERIFIED
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  sed 's/published: "true"/published: "false"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-edited completion_report.published passed verify-seal" A verify-seal LC
  cp "$base/run.bak" .agents/runs/LC/RUN.yaml
  sed 's/^  state: "CODE_DONE"/  state: "PLANNING"/' "$base/run.bak" > .agents/runs/LC/RUN.yaml
  expect_fail "hand-edited execution.state passed verify-seal" A verify-seal LC
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
  expect_fail "orchestrator hot-fix reached VERIFIED after reopen" A handoff LC VERIFIED
  cp "$base/impl.final" impl.txt
  worker FIX pass impl.txt 'impl: trim the key before lookup'
  A handoff LC VERIFIED >/dev/null
  gate_pass independent_reviewer REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass independent_verifier QA; A handoff LC CODE_DONE >/dev/null
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
  echo "lifecycle: orchestrated loop, reopen and ledger passed"
}

# Orchestrated attribution: any change to the application/test tree made
# outside the implementation_worker is detected, before and after review.
scenario_attribution() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC VERIFIED >/dev/null
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null            # independent=false keeps its behaviour
  cp impl.txt "$base/impl.keep"; printf 'late orchestrator edit\n' >> impl.txt
  expect_fail "post-review orchestrator edit passed verify-handoff" A verify-handoff LC
  expect_fail "QA recorded over an unattributed edit" gate_pass full_lifecycle QA
  expect_fail "CODE_DONE over an unattributed edit" A handoff LC CODE_DONE
  expect_fail "stale-recovery VERIFIED laundered an unattributed edit" A handoff LC VERIFIED
  expect_fail "worker window closed outside IMPLEMENTING" A window-close LC "$(tree)" 0
  cp "$base/impl.keep" impl.txt
  A verify-handoff LC >/dev/null                                                # tree is the attested one again
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  echo "lifecycle: orchestrated attribution passed"
}

# Bounded fix loop: a fix stays inside its finding's fix_scope, at most
# max_bounded_fix_attempts fixes per frozen plan, and an explicit plan
# amendment (refreeze) is the escalation valve that returns the run to
# IMPLEMENTING with a fresh budget.
scenario_bounded_fix() {
  scaffold orchestrated false
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC VERIFIED >/dev/null
  gate_fail full_lifecycle REVIEW impl.txt; A handoff LC IMPLEMENTING >/dev/null
  cp impl_test.txt "$base/test.keep"
  worker FIX pass impl_test.txt 'test: tweak outside the finding'
  expect_fail "fix outside the finding's fix_scope reached VERIFIED" A handoff LC VERIFIED
  wopen; cp "$base/test.keep" impl_test.txt; printf 'impl: default for an empty key\n' >> impl.txt; wev FIX pass impl.txt; wclose
  A handoff LC VERIFIED >/dev/null                                              # fix #1, inside fix_scope
  gate_fail full_lifecycle REVIEW impl.txt; A handoff LC IMPLEMENTING >/dev/null   # finding #2
  expect_fail "VERIFIED with no change since the finding" A handoff LC VERIFIED
  worker FIX pass impl.txt 'impl: second attempt at the empty key default'
  A handoff LC VERIFIED >/dev/null                                              # fix #2
  gate_fail full_lifecycle REVIEW impl.txt                                      # finding #3: fixes exhausted
  expect_fail "a third fix was allowed" A handoff LC IMPLEMENTING
  # Escalation: an explicit, authorized plan amendment and refreeze.
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: the finding needs the plan to cover the empty-key contract\n' > .agents/runs/LC/amendments/001.md
  printf 'amended: empty-key contract\n' >> .agents/runs/LC/PLAN.md
  expect_fail "refreeze without an amendment file" A refreeze LC missing.md
  A refreeze LC 001.md >/dev/null
  expect_state handoff state IMPLEMENTING; expect_state handoff verification_patch_sha256 PENDING
  expect_fail "VERIFIED on pre-amendment evidence" A handoff LC VERIFIED
  worker RED fail impl_test.txt 'test: empty key returns the documented default'
  worker GREEN pass impl.txt 'impl: empty key returns the documented default'
  A handoff LC VERIFIED >/dev/null
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  A knowledge-done LC not_applicable >/dev/null; write_report '' '## Amendments' 'Amendment 001 after three failing review gates.'
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null
  A validate LC >/dev/null
  echo "lifecycle: bounded fix loop and escalation passed"
}

# Reopen that needs a plan change: fix_scope beyond the frozen plan is refused
# unless plan_change is declared, and the plan itself only changes through an
# amendment file + refreeze, which the reopen (execution AMENDING) permits.
scenario_amend_plan_change() {
  scaffold standalone false
  solo RED fail impl_test.txt 'test: lookup returns the stored value'; solo GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC VERIFIED >/dev/null; gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null; finish_done
  expect_fail "reopen naming a path outside the frozen plan without plan_change" amend_as full_lifecycle 'the review found a missing helper file the plan did not cover' extra.txt 'add extra.txt with the helper and cover it with a test' 'the user'
  printf 'reason: the review found a missing helper file the plan did not cover\nfix_scope: extra.txt\nfix_instruction: add extra.txt with the helper and cover it with a test\nauthorized_by: the user\nplan_change: yes\n' | A amend LC >/dev/null
  expect_state execution state AMENDING
  expect_fail "plain freeze on a reopened run" A freeze LC
  mkdir -p .agents/runs/LC/amendments; printf '# amendment 001: add extra.txt to scope\n' > .agents/runs/LC/amendments/001.md
  printf '%s\n' '---' 'scope:' '  - path: impl.txt' '    criteria: [AC-1]' '  - path: impl_test.txt' '    criteria: [AC-1]' '  - path: extra.txt' '    criteria: [AC-1]' '---' '# Plan' 'amended' > .agents/runs/LC/PLAN.md
  A refreeze LC 001.md >/dev/null; expect_state handoff state IMPLEMENTING
  solo RED fail impl_test.txt 'test: helper returns the stored value' impl.txt,impl_test.txt,extra.txt; solo GREEN pass extra.txt 'helper: returns the stored value' impl.txt,impl_test.txt,extra.txt
  A handoff LC VERIFIED >/dev/null; gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  A knowledge-done LC not_applicable >/dev/null
  write_report '' '## Amendments' 'Amendment 001 added extra.txt.' '' '## Reopen History' 'Reopened once after DONE to add a helper.'
  A publish-completion-report LC markdown >/dev/null; A handoff LC DONE >/dev/null; A validate LC >/dev/null
  echo "lifecycle: reopen with an authorized plan amendment passed"
}

# A run without the lifecycle_gates key (like EXAMPLE-001) is
# grandfathered: none of the new behaviour applies and none of it is imposed.
scenario_legacy() {
  scaffold orchestrated true no
  expect_fail "gate recorded for a pre-hardening run" gate_pass full_lifecycle REVIEW
  worker RED fail impl_test.txt 'test: lookup returns the stored value'; worker GREEN pass impl.txt 'impl: lookup returns the stored value'
  A handoff LC VERIFIED >/dev/null
  A verify-gates LC >/dev/null; A verify-seal LC >/dev/null
  expect_fail "VERIFIED -> IMPLEMENTING for a pre-hardening run" A handoff LC IMPLEMENTING
  A handoff LC REVIEWED >/dev/null; A handoff LC CODE_DONE >/dev/null       # the original REVIEWED/CODE_DONE semantics
  expect_fail "amend for a pre-hardening run" amend_as full_lifecycle 'a completed historical run must never be reopened in place' impl.txt 'open a new task instead of rewriting history' 'the user'
  [ ! -e .agents/runs/LC/LEDGER.log ] && [ ! -d .agents/runs/LC/gates ]
  echo "lifecycle: pre-hardening (grandfathered) run unchanged passed"
}

# The real wrapper end to end with a stub `codex`: scripts/worker-run.sh
# refuses to start over an unattributed change, attests every worker window
# (including a failed one), and a wrapper-run worker's changes chain cleanly to
# VERIFIED.
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
  A handoff LC VERIFIED >/dev/null
  gate_pass full_lifecycle REVIEW; A handoff LC REVIEWED >/dev/null
  gate_pass full_lifecycle QA; A handoff LC CODE_DONE >/dev/null
  A verify-gates LC >/dev/null
  echo "lifecycle: worker-run.sh wrapper attestation passed"
}

# --- task-source contract -----------------------------------------------------
# Failure scenario: a run freezes its task file, and at completion the file
# legitimately moves todo -> in-progress -> done and its Status changes.
# `freshness` reports the moved file as stale, but if `publish-completion-report`
# never checks freshness and re-hashes the whole file after the adapter appends
# the report, *any* edit made before publish is absorbed and re-baselined.
# A run with `task_source.revision_scheme: contract` freezes only the task
# contract; the Status value and the published report block are bookkeeping;
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
  scaffold standalone false yes yes; f=tasks/in-progress/LC.md; cp "$f" "$base/orig.md"
  ok() { cp "$base/orig.md" "$f"; "$@"; A freshness LC >/dev/null 2>&1 || { echo "FAIL: bookkeeping change rejected: $*" >&2; exit 1; }; }
  bad() { d=$1; shift; cp "$base/orig.md" "$f"; "$@"; if A freshness LC >/dev/null 2>&1; then echo "FAIL: contract change accepted: $d" >&2; exit 1; fi; }
  block() { printf '\n## Completion Report\n\n<!-- COMPLETION-REPORT:BEGIN:%s -->\nreport\n<!-- COMPLETION-REPORT:END:%s -->\n' "$1" "$1" >> "$f"; }
  A freshness LC >/dev/null
  ok tc_status "$f" done
  ok tc_status "$f" 'anything at all, even several words'
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
  cp .agents/runs/LC/RUN.yaml "$base/RUN.saved"
  sed 's/revision_scheme: contract/revision_scheme: bogus/' "$base/RUN.saved" > .agents/runs/LC/RUN.yaml
  tc_expect_msg "an unknown revision scheme was accepted" 'unsupported task_source.revision_scheme' A freshness LC
  cp "$base/RUN.saved" .agents/runs/LC/RUN.yaml
  echo "lifecycle: task-source contract projection passed"
}

# Runs frozen before the contract scheme (no revision_scheme key) keep the original
# whole-file semantics exactly, and are never re-pointed.
scenario_task_contract_legacy() {
  scaffold standalone false yes no; tc_to_code_done standalone; frozen=$(rv task_source revision)
  [ -z "$(rv task_source revision_scheme)" ]
  tc_expect_msg "task-source-relocate accepted a pre-contract run" 'pre-contract' A task-source-relocate LC tasks/x.md
  finish_done
  [ "$(rv task_source revision)" != "$frozen" ] || { echo "FAIL: a pre-contract run no longer refreshes its whole-file revision at publish" >&2; exit 1; }
  A freshness LC >/dev/null; A delivery-check LC >/dev/null; A validate LC >/dev/null
  echo "lifecycle: pre-contract task-source semantics unchanged passed"
}

run_sc scenario_standalone claude
run_sc scenario_standalone codex short
run_sc scenario_independence
run_sc scenario_orchestrated_loop
run_sc scenario_attribution
run_sc scenario_worker_wrapper
run_sc scenario_bounded_fix
run_sc scenario_amend_plan_change
run_sc scenario_legacy
run_sc scenario_task_contract_bookkeeping standalone
run_sc scenario_task_contract_bookkeeping orchestrated
run_sc scenario_task_contract_edit standalone
run_sc scenario_task_contract_edit orchestrated
run_sc scenario_task_contract_laundering
run_sc scenario_task_contract_relocate
run_sc scenario_task_contract_adapter
run_sc scenario_task_contract_projection
run_sc scenario_task_contract_legacy
echo 'agent lifecycle tests passed'

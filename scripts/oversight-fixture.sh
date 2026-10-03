# oversight-fixture.sh: builds synthetic run directories with the exact file shapes
# agent.sh writes, for the oversight tests. Source it; it defines fx_* functions.
# A fixture is a throwaway repository root under $FX_BASE (the caller removes it).

fx_new() { # -> sets FX_ROOT, FX_DIR, FX_ID
  FX_N=$(( ${FX_N:-0} + 1 ))
  FX_ROOT=$FX_BASE/fx$FX_N; FX_ID=T-1; FX_DIR=$FX_ROOT/.agents/runs/$FX_ID; FX_LED=0
  mkdir -p "$FX_DIR" "$FX_ROOT/.agents/modes"
  printf 'pipelines:\n  COMPLEX:\n    evidence: yes\n    qa: yes\n    review: yes\n    architect: yes\n  TRIVIAL:\n    evidence: no\n    qa: no\n    review: no\n    architect: no\n' > "$FX_ROOT/.agents/config.yaml"
  printf 'mode: deterministic\nverification:\n  max_bounded_fix_attempts: 2\n' > "$FX_ROOT/.agents/modes/deterministic.yaml"
}

fx_run() { # HANDOFF STATE [TOPOLOGY]
  cat > "$FX_DIR/RUN.yaml" <<EOT
task:
  id: T-1
repository:
  base_sha: "abc123"
  task_branch: "task/t-1"
task_source:
  path: tasks/T-1.md
execution:
  mode: deterministic
  state: $2
  knowledge_state: not_started
  topology: ${3:-standalone}
pipeline:
  classification: COMPLEX
  review: yes
freeze:
  task_sha256: "t1"
  evidence_sha256: "e1"
  plan_sha256: "p1"
  qa_plan_sha256: "q1"
  policy_sha256: "pol"
  pipeline: "COMPLEX:review=yes"
baseline:
  status: captured
handoff:
  state: $1
  implemented_patch_sha256: "impl1"
  code_done_patch_sha256: PENDING
completion_report:
  published: false
EOT
}

fx_docs() { # AC-text...  (each argument is one acceptance criterion line)
  { printf '# Task: T-1\n\n## Acceptance criteria\n\n'; for a in "$@"; do printf -- '- %s\n' "$a"; done; } > "$FX_DIR/TASK.md"
  printf -- '---\nscope:\n  - path: src/a.go\n    criteria: [AC-1]\n  - path: src/a_test.go\n    criteria: [AC-1]\n---\n# Plan\n' > "$FX_DIR/PLAN.md"
  printf '# Evidence\n\nAC-1 is implemented in `src/a.go:Lookup`.\nGeneral note about src/b.go:Other.\n' > "$FX_DIR/EVIDENCE.md"
  printf '# QA\n\n- QA-1 (AC-1): lookup returns the stored value\n- QA-2 (AC-1): empty key returns default\n' > "$FX_DIR/QA_PLAN.md"
  printf '# QA report\n\nVerdict: PASS\n\n- QA-1: PASS — observed stored value\n- QA-2: PASS — default returned\n' > "$FX_DIR/QA_REPORT.md"
  printf '# Verify\n\nVerdict: PASS\n\n## Commands\n\n- `go test ./...` | exit=0\n- `go vet ./...` | exit=0\n- `free text without exit`\n\n## Plan conformance\n\nok\n' > "$FX_DIR/VERIFY.md"
}

fx_ledger() { # EVENT FROM TO DETAIL [ROLE]
  FX_LED=$((FX_LED + 1))
  printf 'seq=%s prev=x event=%s role=%s from=%s to=%s digest=d ts=2026-01-01T00:00:%02dZ detail=%s\n' "$FX_LED" "$1" "${5:-full_lifecycle}" "$2" "$3" "$((FX_LED % 60))" "$4" >> "$FX_DIR/LEDGER.log"
}

fx_gate() { # SEQ GATE RESULT PATCH [extra yaml line]...   (also appends the ledger event)
  fg_seq=$1 fg_gate=$2 fg_res=$3 fg_patch=$4; shift 4
  case "$fg_gate" in REVIEW) fg_who=reviewer ;; QA) fg_who=qa ;; *) fg_who=verifier ;; esac
  fg_name=$(printf '%03d-%s' "$fg_seq" "$fg_gate")
  mkdir -p "$FX_DIR/gates"
  {
    printf 'task_id: "T-1"\nseq: %s\ngate: "%s"\nresult: "%s"\nrole: "independent_%s"\ntopology: "standalone"\npatch_sha256: "%s"\nmanifest_sha256: "m"\n' "$fg_seq" "$fg_gate" "$fg_res" "$fg_who" "$fg_patch"
    printf 'report: "X.md"\nreport_sha256: "r"\ntask_sha256: "t1"\nevidence_sha256: "e1"\nplan_sha256: "p1"\nqa_plan_sha256: "q1"\npolicy_sha256: "pol"\npipeline: "COMPLEX:review=yes"\nsummary: inspected the whole diff of the tree\n'
    for fg_x in "$@"; do printf '%s\n' "$fg_x"; done
    printf 'timestamp: "2026-01-01T00:00:0%sZ"\n' "$((fg_seq % 10))"
  } > "$FX_DIR/gates/$fg_name.yaml"
  printf 'src/a.go|%s\nsrc/a_test.go|%s\n' "$fg_patch" "$fg_patch" > "$FX_DIR/gates/$fg_name.manifest"
  fx_ledger "gate:$fg_gate:$fg_res" IMPLEMENTED IMPLEMENTED "$fg_name by independent" "${FX_GATE_LEDGER_ROLE:-full_lifecycle}"
}

fx_evidence() { # PHASE SEQ RESULT TARGET [ROLE]
  mkdir -p "$FX_DIR/worker-evidence"
  fe_exp=''; [ "$1" != RED ] || fe_exp='expected_failure: lookup is not implemented yet'
  printf 'task_id: "T-1"\nphase: "%s"\nresult: "%s"\nrole: "%s"\ncommand: go test ./...\ntarget: %s\n%s\ntimestamp: "2026-01-01T00:01:0%sZ"\n' "$1" "$3" "${5:-full_lifecycle}" "$4" "$fe_exp" "$2" > "$FX_DIR/worker-evidence/$1-$2.yaml"
}

# fx_complete: a finished-looking run: one failed REVIEW, a fix, then three passes.
fx_complete() {
  fx_new; fx_run IMPLEMENTED PLANNING
  fx_docs "AC-1: lookup returns the stored value" "AC-2: unrelated requirement" "AC-10: tenth requirement"
  fx_evidence RED 1 fail src/a_test.go; fx_evidence GREEN 1 pass src/a.go,src/a_test.go
  fx_ledger classify PLANNED PLANNED "COMPLEX review=yes"
  fx_gate 1 REVIEW fail impl1 "findings: lookup is wrong for an empty key" "fix_scope: src/a.go" "fix_instruction: return the default for an empty key"
  fx_ledger handoff:IMPLEMENTING IMPLEMENTED IMPLEMENTING ""
  fx_ledger handoff:IMPLEMENTED IMPLEMENTING IMPLEMENTED ""
  fx_gate 2 REVIEW pass impl2; fx_gate 3 QA pass impl2; fx_gate 4 VERIFY pass impl2
}

# ---- portability ------------------------------------------------------------------------------------
# The documented minimum platform of the control plane is sh, git, awk, sed and shasum (curl is optional,
# for event emission). shasum is an existing prerequisite of the control plane (agent.sh already calls it); it is
# not guaranteed to be a native binary: on macOS it can itself be a perl script, and minimal Linux images may not
# ship it. This list does not remove that
# prerequisite and adds no sha256sum fallback. The oversight layer itself also uses these standard tools, and nothing else:
#   dirname mkdir mktemp mv rm   paths, temp files in the target directory, atomic report write
#   tr cmp                       skip binary untracked files in the diffstat
# (date is needed only by event.sh, and only when curl exists.)
PORTABLE_TOOLS="sh awk sed git shasum dirname mkdir mktemp mv rm tr cmp"

# awk_engines: every distinct awk found: BSD awk, the one on PATH, gawk, mawk, nawk, $OVS_EXTRA_AWKS.
awk_engines() {
  ae_list=''
  for ae_c in /usr/bin/awk "$(command -v awk)" "$(command -v gawk 2>/dev/null || true)" "$(command -v mawk 2>/dev/null || true)" "$(command -v nawk 2>/dev/null || true)" ${OVS_EXTRA_AWKS:-}; do
    [ -n "$ae_c" ] && [ -x "$ae_c" ] || continue
    ae_dup=0; for ae_k in $ae_list; do if cmp -s "$ae_c" "$ae_k"; then ae_dup=1; fi; done
    [ "$ae_dup" = 1 ] || ae_list="$ae_list $ae_c"
  done
  printf '%s\n' "$ae_list"
}

# restricted_path DIR AWK: DIR holds symlinks to PORTABLE_TOOLS only, with AWK as awk. Run with PATH=DIR.
restricted_path() {
  mkdir -p "$1"
  for rp_t in $PORTABLE_TOOLS; do
    [ "$rp_t" = awk ] && continue
    rp_src=$(command -v "$rp_t") || { echo "FAIL: required tool missing on this machine: $rp_t" >&2; exit 1; }
    ln -sf "$rp_src" "$1/$rp_t"
  done
  ln -sf "$2" "$1/awk"
  for rp_a in go node python python3 jq ruby perl curl; do
    if PATH=$1 command -v "$rp_a" >/dev/null 2>&1; then echo "FAIL: $rp_a is on the restricted PATH" >&2; exit 1; fi
  done
}

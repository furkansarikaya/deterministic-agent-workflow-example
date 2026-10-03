# Verification: <TASK-ID>

Owner: Verifier. Question: did we implement the frozen plan, and can the repository prove it? Run the commands. MUST NOT edit the implementation to obtain a pass.

Verdict: PASS | FAIL | BLOCKED

## Commands

- `<exact command>` | exit=<n>
  output: <the relevant output, one short line>

Record the relevant output under each command as an indented `output:` line (what shows it passed, or why it failed). The `| exit=<n>` suffix is machine-read; the output line is for people.

## Plan conformance

Every frozen scope path exists and changed as planned. Record `agent.sh verify-scope`, `verify-freeze` and `verify-worker-evidence` results, and lint or static analysis where repository rules require it.

## Failures

FAIL: the failing command and output, plus the `fix_scope` and fix instruction the gate record carries. BLOCKED: the environment or tooling problem. A BLOCKED verdict records no gate.

# Verification: <TASK-ID>

Owner: Verifier. Did we implement the frozen plan, and can the repository prove it? Run the commands; never edit the implementation to obtain a pass.

Verdict: PASS | FAIL | BLOCKED

## Commands

- `<exact command>` — exit status and the relevant output

## Plan conformance

<every frozen scope path exists and changed as planned; `agent.sh verify-scope`, `verify-freeze`, `verify-worker-evidence` results; lint/static analysis where the repository rules require it>

## Failures

<for FAIL: the failing command and output, and the fix_scope/fix instruction the gate record will carry. For BLOCKED: the environment/tooling problem; no gate is recorded.>

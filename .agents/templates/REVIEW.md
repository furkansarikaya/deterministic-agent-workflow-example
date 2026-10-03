# Review: <TASK-ID>

Owner: Reviewer. Judge the actual diff against TASK, frozen EVIDENCE and PLAN, and the engineering rules. "Tests passed" is not a review. MUST NOT repair code.

Verdict: PASS | FAIL

## Inspected

<paths and symbols reviewed>

## Findings

Cover correctness, maintainability, architecture compliance, security, needless complexity, scope expansion and shortcuts. Give each finding as `path:line` and the reason. FAIL: add the `fix_scope` and fix instruction the gate record carries, plus optional `severity` and `category`.

---
name: oversight-report
description: Produce a disposable HTML oversight report for one task from existing workflow files. Use only when the user asks for a report, summary page or visual overview of a task. Not evidence.
---

# Oversight report

The report is presentation. It is not evidence, a gate or a verdict. It MUST NOT approve or reject work.

## When

- Run `./scripts/agent.sh report [TASK-ID]` only when the user asks for a report.
- MUST NOT run it on your own initiative. MUST NOT run it as a workflow step.
- For a terminal overview, run `./scripts/agent.sh summary [TASK-ID]`.

## Steps

1. Read the workflow facts. Use `agent.sh summary`, `RUN.yaml`, the gate records, `LEDGER.log`, worker evidence, `TASK.md`, `PLAN.md`, `EVIDENCE.md`, `QA_*.md`, `VERIFY.md` and git state.
2. Classify each fact you state as recorded, derived or unavailable.
   - Recorded: a workflow file states it.
   - Derived: you or `agent.sh report` computed it from recorded files.
   - Unavailable: no file states it. Write `unavailable`.
3. MUST NOT invent a fact. MUST NOT estimate an unavailable value.
4. MUST NOT include prompts, model responses, hidden reasoning, source code, diffs or patches. Paths and line counts only.
5. Run `./scripts/agent.sh report [TASK-ID]`. It prints the page path.
6. Give the user the path. STOP.

## Output

- The page is `${TMPDIR:-/tmp}/agent-oversight-<repo hash>/<TASK-ID>.html`, outside the repository.
- The template is `assets/report-template.html`. It is static and makes no network request.
- The page is disposable. `agent.sh cleanup` deletes it. `report` deletes pages older than 7 days.
- MUST NOT copy the page into the repository. MUST NOT commit it. There is no `--out` option.
- A role that is expected but left no record is shown as `expected, no record`. Expected is not proof.

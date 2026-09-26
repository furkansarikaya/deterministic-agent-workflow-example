# Task-integration adapters

`agent.sh` (`publish-completion-report` / `verify-completion-report`) never
talks to a specific task tracker. It only validates the Task Completion
Report's minimum structure, then delegates to whichever adapter script is
named in the run's `completion_report.adapter` field. An adapter is a
standalone script implementing exactly two operations:

```sh
<adapter>.sh publish <TASK-ID> <report-file>   # prints a receipt to stdout
<adapter>.sh verify  <TASK-ID> <receipt>       # exit 0 iff still present/correct
```

The receipt is an opaque string as far as `agent.sh` is concerned — it is
recorded in `RUN.yaml` (`completion_report.receipt`) and handed back to
`verify` unmodified. What "publish" means — append to a Markdown file,
comment on an issue, post to a chat channel — is entirely the adapter's
concern; the deterministic control plane understands only the two
operations above, never provider-specific storage.

## `markdown.sh`

The default/reference adapter. Its native activity surface is the task's
own `local_markdown` source file (`task_source.path` in `RUN.yaml`): it
appends the report under an idempotent, delimited `## Completion Report`
section and returns a `<path>#<sha256-of-report-body>` receipt. Re-publishing
replaces the prior section rather than duplicating it.

## Writing into the task source

For a local Markdown task source (see `.agents/WORKFLOW.md`,
"Task-source contract"), `agent.sh` checks that the frozen
task contract is fresh before it calls `publish` and again immediately after.
The **only** part of a local Markdown task source an adapter may change is the one
block `markdown.sh` writes: the `## Completion Report` heading, a blank line, the
`<!-- COMPLETION-REPORT:BEGIN:<TASK-ID> -->` marker, the report, and the matching
`END` marker. If `publish` changes anything else, `agent.sh` restores the task source
byte for byte, records nothing, and fails. An adapter that does not write into the
task source (an issue-tracker adapter, say) is unaffected.

## Adding another adapter

Copy the two-operation contract above. A new adapter must not require any
change to `agent.sh` itself — that is the point of the boundary. Keep
provider-specific logic (auth, API calls, formatting) entirely inside the
adapter script.

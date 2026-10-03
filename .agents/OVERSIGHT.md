# Human oversight

Canonical run state → oversight model → CLI summary, HTML report, diagrams. The model, summary and report are a **projection**. They MUST NOT be treated as truth, evidence or a gate. Load this file only when you run, change or review oversight output or workflow events.

## Invariants

- The model MUST NOT hold a fact that run state lacks. A value run state lacks is `unavailable` (JSON `null`). The builder MUST NOT estimate it.
- Summary and report MUST read only the model. Neither MUST write run state, evidence, plan, source, tests, knowledge or gates.
- Output MUST be deterministic: same run state and repository, same bytes, on every awk engine. Rendering MUST NOT call an LLM, the network, a font or CDN, a clock or a random source.
- Report generation MAY fail. A failure MUST NOT fail or block any task command.
- Reports are disposable. They are written to `.agents/runtime/reports/<TASK-ID>.html` (git-ignored) and MUST NOT be committed. `--out` is available to `full_lifecycle` only; every other role writes the default path and nothing else. `oversight.sh` compares inodes (`-ef`), not strings, and refuses a target that is, or lies inside, `.agents/runs/` (any letter case, symlink or `..`), is a symlink, a directory, or an existing tracked file. The report is rendered to a unique temp file in the target directory and moved into place, so a planted `<target>.tmp` symlink is never followed. The message names the repo-relative path (or the path as given).
- Oversight MUST NOT need an application-language toolchain: it uses only the minimum platform in `.agents/ENGINEERING.md`, plus `dirname`, `mkdir`, `mktemp`, `mv`, `rm`, `tr` and `cmp`.

## Commands

```sh
./scripts/agent.sh summary [TASK-ID]                 # concise text; names the report only if one exists
./scripts/agent.sh report [TASK-ID] [--out FILE]     # self-contained HTML; works for active and finished runs
./scripts/agent.sh oversight-model [TASK-ID]         # the model as JSON
```

`TASK-ID` defaults to the active run. Every role MAY run `summary` and `report`. `oversight-model` is available to `full_lifecycle` and `implementation_worker` only. Only `full_lifecycle` MAY pass `report --out`. Nothing is built or installed.

## Implementation (`scripts/oversight/`, sh and POSIX awk)

| File | Does |
|---|---|
| `oversight.sh` | Driver: arguments, file index, git diffstat (counts only), report write and refusal rules |
| `model.awk` | Run directory → model records. The only parser of run state |
| `json.awk`, `summary.awk`, `report.awk`, `svg.awk` | Model records → JSON, CLI summary, HTML, diagrams. They read the model only |
| `lib.awk`, `mload.awk`, `diffstat.awk` | Shared helpers (escaping, ordering, provenance), model loader, numstat join |
| `report.css` | Inline page stylesheet (the page carries no script) |
| `event.sh` | `workflow-event/1` emitter |

The model is a record stream `kind US index US field US value` (US = byte 0x1f). Summary, JSON and HTML are three views of it.

## Model

Schema `oversight-model/1`. Every scalar carries a source: **recorded** (read verbatim), **derived** (computed from recorded values) or **unavailable**. Sections: task, status, topology, pipeline, roles and delegations, lifecycle (only the stages the pipeline applies), flow (the ledger), attempts, gate records, findings, remediation loops, acceptance criteria, QA scenarios, links, evidence refs, changed files with diffstat, tests, verification, fingerprints, outcome, durations, and the list of unavailable items.

- Order is stable: sequence numbers, natural order (`AC-2` before `AC-10`), sorted paths.
- A link (requirement → plan file → QA scenario → evidence record) exists only where PLAN scope, QA_PLAN, QA_REPORT, EVIDENCE.md or worker evidence states it.
- Durations come only from recorded `duration_s`. Diffstat counts lines through `git diff --numstat`. No source content enters the model.
- A finding is one failing gate record. `severity` (`critical|major|minor`) and `category` (`correctness|security|scope|test|behavior|maintainability|other`) are recorded only when the gate record carries them. A later pass of the same gate resolves the finding. Remediation loops come from findings and ledger entries only.
- Verifier commands come from `VERIFY.md` lines ``- `command` | exit=N``. QA results come from `- QA-n: PASS|FAIL — note`.
- The model labels a gate record "bound to the current contract" by comparing recorded hashes. It does not verify integrity: use `verify-gates`, `validate` and `delivery-check`.
- **Roles.** A role has three separate facts. *Recorded*: a gate record, worker evidence or ledger entry names the role (`executed`, `records`, `activity`). *Expected*: the pipeline or topology says the role takes part (`expected`, `expectedBy`: derived). *Unavailable*: expected, with no record, so no execution evidence (`status: expected_no_record`). Expected is not proof. A delegation edge is `recorded` only when the delegate left records, otherwise `expected`.

## Report

One file, inline CSS and SVG, no script. Light and dark by `prefers-color-scheme`. Responsive. Sections: overview, execution flow, remediation, acceptance criteria, changed files, findings, verification, provenance. Diagrams (lifecycle flow, remediation loops, criteria evidence graph, roles and topology) use a fixed arithmetic layout. All text is HTML-escaped. A role that left no record is drawn dashed and labelled `expected · no record`. The provenance section states that the report is not evidence.

## Observability contract (observer only)

Optional. Set `AGENT_WORKFLOW_EVENTS_URL` to an `http(s)` URL and `agent.sh` POSTs one JSON event per transition with `curl`. `curl` is optional: without it, emission is a silent no-op. Emission is fail-open: an unset URL is a no-op, each request is limited to 0.3 s (`--connect-timeout 0.2 --max-time 0.3`; a curl that rejects fractions is retried once with whole seconds, only because it sent nothing), there are no retries, every failure is silent, and no command ever fails because of it. The receiver is never required and never consulted.

```json
{"schema":"workflow-event/1","event":"stage|gate|attempt|remediation|outcome|report","runRef":"<task id>","seq":1,
 "stage":"discover|evidence|plan|implement|review|qa|verify|code_done|knowledge|done",
 "status":"started|passed|failed|blocked|skipped|completed",
 "gate":"review|qa|verify","attempt":1,"role":"<role>","topology":"standalone|orchestrated",
 "findingsOpen":0,"loop":0,"fingerprint":"<sha256 hex>","reportAvailable":true,"at":"<ISO time at emit, milliseconds .000>"}
```

`gate`, `attempt`, `role`, `topology`, `findingsOpen`, `loop`, `fingerprint` and `reportAvailable` are optional. `seq` is monotonic per run, kept in `.agents/runtime/events/`. A missing counter is seeded from the epoch seconds (`date +%s`), so a recreated counter never reuses small values and a collector never drops the new events as duplicates; afterwards it grows by one per event.

**`runRef` is the task id and MUST be unique across the repositories reporting to one collector** (the collector keys on `runRef` plus `seq`; two checkouts using the same task id would collide).

**`role` is the role that emitted or recorded the event**: the invoking `AGENT_ROLE`. It is never the role that is merely expected to act. `decide` and `decision-outcome` are `full_lifecycle` commands, so their `attempt` events carry `full_lifecycle`; the implementation worker appears only on events it emitted itself. Every value is validated against its enum or pattern. An invalid value drops the whole event.

**Privacy boundary.** An event MUST NOT carry prose, titles, paths, source, prompts or findings text. Events carry identifiers, enums, counters and hashes only.

**Provider session correlation.** If the caller sets both `AGENT_SESSION_PROVIDER` (`claude|codex`) and `AGENT_SESSION_ID`, events add `"providerSession":{"provider":"…","sessionId":"…"}`. The control plane does not verify it.

Emit points: `classify` (discover started), `freeze` (evidence, plan completed), `handoff` (implement started and completed, code_done passed, done outcome), `gate` (review, qa, verify), bounded fix start (remediation), `decide` and `decision-outcome` (attempt), `knowledge-done`, `terminate` (outcome), and `report`.

## Tests

`scripts/oversight-model-test.sh` (model, report, roles, events, large run, portability on fixtures) and `scripts/oversight-test.sh` (end to end through `agent.sh`, events through a stub `curl`, restricted-PATH portability under every awk engine found; `OVS_EXTRA_AWKS="/path/gawk /path/mawk"` adds engines). `agent.sh test` runs both.

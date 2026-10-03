# Human oversight

Run state is canonical. Summary and report are presentation. They MUST NOT be treated as truth, evidence or a gate.

- `./scripts/agent.sh summary [TASK-ID]` prints concise status lines. Every role MAY run it. It reads run files and writes nothing. A fact the files lack prints `unavailable`.
- `./scripts/agent.sh report [TASK-ID]` writes one disposable HTML page. Run it only when the user asks. `.agents/skills/oversight-report/SKILL.md` governs it. Every role MAY run it.
- The page is written to `${TMPDIR:-/tmp}/agent-oversight-<repo hash>/<TASK-ID>.html` in a mode 700 directory outside the repository. There is no `--out`. The command refuses a symlink target and a temporary directory inside the repository.
- `agent.sh cleanup <TASK-ID>` deletes that task's page. `report` deletes `*.html` files older than 7 days in that directory.
- Neither command changes a run artifact or a gate. A failure of either MUST NOT block a workflow command.
- Workflow events (`scripts/oversight/event.sh`, optional, fail-open): the contract is the header of that file.
- Tests: `scripts/oversight-test.sh`.

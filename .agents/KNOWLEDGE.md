# Knowledge precedence and deterministic read contract

Resolve conflicts: (1) explicit task, (2) current behavior/tests, (3) canonical docs, (4) wiki decisions, (5) lessons/history, (6) skill guidance, (7) model preference.

Examples: task forbidding dependencies beats a skill recommending a library; current tests beat a stale lesson; canonical file storage beats a wiki database suggestion.

Wiki retrieval is on-demand, not a mandatory task step. Start with TASK plus current repository/tests; query the wiki only when that evidence is insufficient. When needed, traverse only `index → relevant entities → decisions → lessons → concepts → sources`, expanding only until the missing fact is resolved. Freeze references and derived constraints in evidence; do not copy pages. After freeze, unrelated retrieval is prohibited; missing information triggers amendment. Never bulk-load `docs/wiki/**`, unrelated historical runs, or session history.

Transaction A is code through CODE DONE, wiki read-only. Transaction B is optional: it runs only when the task changed a durable project contract or documented architecture (factual summary → ingestion → decision/lesson → log → lint → KNOWLEDGE DONE); otherwise record `knowledge-done <ID> not_applicable`. Run artifacts (evidence, plans, QA, reviews) are disposable and are never promoted wholesale into the wiki. A task cannot rewrite its own past.

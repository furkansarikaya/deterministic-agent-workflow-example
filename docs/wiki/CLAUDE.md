# Wiki rules

This Git-backed Markdown wiki is a knowledge graph; Obsidian is optional visualization only. Current repository state and canonical documentation outrank it.

1. Every important claim has a source.
2. Contradictions are never silently deleted; mark them explicitly.
3. Use meaningful bidirectional relationships.
4. Log every wiki operation in [[log]].
5. Archive outdated pages; do not delete them.
6. One concept or decision generally maps to one page.
7. Current repository state outranks stale wiki interpretation.
8. Wiki knowledge never overrides explicit task requirements.
9. Canonical project documentation remains canonical.
10. Every source field must resolve to an existing repository path; task references must resolve to real runs.
11. Contradicted pages use `status: contradicted` and `contradicts:` metadata; archive rather than erase history.

During deterministic code execution, wiki access is read-only and limited to task-relevant traversal: [[index]] → entities → decisions → lessons → concepts → sources. Do not write syntheses, logs, or pages during this transaction. After CODE DONE, use the separate knowledge transaction described in [[KNOWLEDGE-PIPELINE]]; raw session summaries are factual and immutable once ingested. `wiki-lint.sh` reports findings and never silently rewrites knowledge.

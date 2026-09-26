# Wiki rules

This Git-backed Markdown wiki is a knowledge graph; Obsidian is optional visualization only. Current repository state and canonical documentation outrank it.

1. Important claims have sources.
2. Contradictions are explicit, never silently deleted.
3. Use meaningful bidirectional relationships.
4. Log actual INGEST or filed-back QUERY operations in [[log]].
5. Archive outdated pages instead of deleting them.
6. One concept or decision generally maps to one page.
7. Explicit task requirements outrank wiki knowledge.
8. Source paths resolve to repository files. A task ID is history, not a link: run directories are disposable and never referenced as sources.
9. Contradicted pages use `status: contradicted` and `contradicts:` metadata.

## Deterministic adaptation

During Transaction A, `/wiki-query`-style retrieval is read-only: follow [[index]] → entity → decision → lesson → concept → source, freeze selected references in EVIDENCE, and do not file back synthesis or update log/index/entities/concepts/decisions/lessons.

After CODE DONE, Transaction B (optional, only for a changed durable contract) may use the user's `/wiki-ingest` and `/wiki-lint` operations. Ingest keeps its normal review/approval semantics; lint reports findings rather than silently fixing them. The repository's `scripts/wiki-lint.sh` is a compact structural example, not a replacement for the global skill.

# TodoFlow — Linear ile Deterministic Agent Workflow Örneği

## Hedef

Bu dosya yalnız Linear kullanan projeler için kısa operasyon rehberidir.

## Mapping

```text
Linear Team       → ürün/ekip
Linear Project    → ürün initiative/MVP
Linear Cycle      → sprint
Linear Issue      → yapılacak iş
.agents/runs/ID   → issue'nun deterministic execution contract'ı
docs/wiki         → kalıcı proje bilgisi
```

## Örnek

Team:

```text
TodoFlow
```

Project:

```text
TodoFlow MVP
```

Cycle:

```text
Sprint 1 — Todo Core
```

Issues:

```text
TODO-1 Create todo
TODO-2 List todos
TODO-3 Complete todo
TODO-4 Delete todo
```

## Issue formatı

```md
# Create todo endpoint

Implement todo creation.

Acceptance Criteria:
- POST `/api/v1/todos`
- title required
- description optional
- created todo defaults to incomplete
- persisted in PostgreSQL
- HTTP 201
- relevant tests pass

Constraints:
- no new NuGet packages
- no unrelated CRUD work
```

## Task başlatma

Linear issue seç:

```text
TODO-1
```

Run oluştur:

```text
.agents/runs/TODO-1/
```

`ACTIVE_RUN`:

```text
TODO-1
```

Baseline:

```bash
./scripts/agent.sh baseline TODO-1
```

Ardından:

```text
DISCOVER
→ EVIDENCE
→ PLAN
→ FREEZE
→ IMPLEMENT
→ VERIFY
→ REVIEW
→ CODE DONE
```

## Status mapping

Öneri:

```text
Linear Todo
→ In Progress    (run aktive edildiğinde)
→ In Review      (opsiyonel)
→ Done           (CODE DONE sonrası)
```

Linear state, deterministic gate'lerin yerine geçmez.

## Completion comment

```md
Implemented TODO-1.

Changed:
- create todo application flow
- POST /api/v1/todos
- persistence mapping
- tests

Verification:
- build: PASS
- tests: PASS
- freeze: PASS
- scope: PASS

No new dependencies.
```

## Wiki

Linear issue geçmişi wiki değildir.

Yeni reusable decision/lesson oluştuysa CODE DONE sonrası:

```text
/wiki-ingest
/wiki-lint
```

kullan.

## Token kuralı

Agent yalnız aktif issue'yu ve ilgili repository evidence'ını okumalıdır.

Tüm Linear project/cycle/backlog context'e yüklenmemelidir.

## Execution role örneği

Linear yalnız task-management bağlamıdır; execution role'ü belirlemez.

```text
Linear TODO-123
→ Claude run'ı çözer/oluşturur, PLAN/FREEZE yapar
→ explicit Codex implementation_worker
→ Claude VERIFY/REVIEW
→ izin varsa task-management güncellemesi
```

Codex-only `full_lifecycle` kullanım da geçerlidir; Linear zorunlu
değildir. Claude → Codex normal resume ile delegated worker invocation
farklıdır: normal başlayan Codex aynı run'ın tüm lifecycle'ını sürdürebilir.

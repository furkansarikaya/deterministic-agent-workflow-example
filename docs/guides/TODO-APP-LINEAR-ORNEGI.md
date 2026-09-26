# TodoFlow — Linear ile Deterministic Agent Workflow

Yalnız Linear kullanan projeler için kısa operasyon rehberi. Genel model ve prompt kuralı: [Agent Session ve Prompt Rehberi](AGENT-SESSION-VE-PROMPT-REHBERI.md).

## Mapping

```text
Linear Team / Project / Cycle → ürün / MVP / sprint
Linear Issue                  → yapılacak iş (task kaynağı)
.agents/runs/<ISSUE-ID>       → geçici execution state (task bitince silinir)
docs/wiki                     → kalıcı proje bilgisi
```

Linear "hangi iş yapılacak?" sorusunu cevaplar; run "bu iş nasıl güvenli ve deterministik yapılıyor?" sorusunu. Linear state'i gate'lerin yerine geçmez.

## Issue formatı

```md
# Create todo endpoint

Acceptance Criteria:
- POST `/api/v1/todos`; title required; description optional
- created todo defaults to incomplete; HTTP 201
- relevant tests pass

Constraints:
- no new NuGet packages; no unrelated CRUD work
```

Issue'nun kabul kriterleri ve kısıtları agent'ın run'daki `TASK.md` sözleşmesine dönüşür. Linear issue'su yerel bir Markdown dosyası olmadığı için run'ın `task_source` alanı `type: none` (`revision: not_applicable`) olur; yani task kaynağı için freshness kontrolü yapılmaz ve issue'daki sonradan değişiklikleri sen amendment olarak iletmelisin.

## Kullanım

```text
Work on Linear issue TODO-1.
```
```text
Linear'daki TODO-1 issue'su üzerinde çalış.
```

Lifecycle, sınıflandırma, delegation, gate'ler ve cleanup repository tarafından yürütülür; prompt'a yazılmaz.

## Completion report ve adapter

`DONE` için completion report'un bir task-integration adapter'ı ile yayınlanıp doğrulanması gerekir. Bu repository yalnız `markdown` adapter'ını taşır (yerel task dosyasına yazar). Linear için `.agents/task-integrations/linear.sh` gibi bir adapter'ı sen yazarsın; sözleşme yalnız `publish <TASK-ID> <report-file>` (receipt yazdırır) ve `verify <TASK-ID> <receipt>` işlemleridir (`.agents/task-integrations/README.md`). `agent.sh` Linear'a özel hiçbir şey bilmez. Adapter yoksa run `DONE`'a ulaşamaz.

## Status mapping (öneri)

```text
Linear Todo → In Progress (run aktive edilince) → Done (DONE ve yayın sonrası)
```

Bu güncellemeler task-system yazımıdır; açık yetkin olmadan yapılmaz.

## Wiki ve token

Linear geçmişi wiki değildir. Kalıcı bir sözleşme/karar değiştiyse knowledge transaction (`/wiki-ingest`, `/wiki-lint`) çalışır; aksi halde `not_applicable`. Agent yalnız aktif issue'yu ve ilgili repository kanıtını okur; tüm project/cycle/backlog context'e yüklenmez.

## Execution role

Linear execution role'ünü belirlemez. Aynı issue'yu Claude Code veya Codex normal `full_lifecycle` olarak baştan sona yürütebilir; `orchestrated` topology'de implementation `implementation_worker`'a gider. Bu, repository config'inin (`default_topology`) işidir, prompt'un değil.

# TodoFlow — Markdown ile Task ve Sprint Yönetimi Örneği

## Hedef

Linear kullanmak istemeyen ekipler için Git-backed project management örneği.

Deterministic execution dosyaları ile project-management dosyalarını ayır. Genel model ve prompt kuralı: [Agent Session ve Prompt Rehberi](AGENT-SESSION-VE-PROMPT-REHBERI.md).

```text
docs/project/
    = roadmap/backlog/sprint/task yönetimi

.agents/runs/
    = geçici execution state (task bitince silinir, commit edilmez)

docs/wiki/
    = semantic project knowledge
```

## Önerilen yapı

```text
docs/
└── project/
    ├── ROADMAP.md
    ├── BACKLOG.md
    ├── sprints/
    │   ├── SPRINT-001.md
    │   └── SPRINT-002.md
    └── tasks/
        ├── TODO-001.md
        ├── TODO-002.md
        ├── TODO-003.md
        └── TODO-004.md
```

## ROADMAP.md

```md
# TodoFlow Roadmap

## MVP
- Create todo
- List todos
- Complete todo
- Delete todo

## Later
- Tags
- Due dates
- Priority
- Authentication
```

## BACKLOG.md

```md
# Backlog

| ID | Title | Priority | Status | Sprint |
|---|---|---|---|---|
| TODO-001 | Create todo | High | Todo | SPRINT-001 |
| TODO-002 | List todos | High | Todo | SPRINT-001 |
| TODO-003 | Complete todo | High | Todo | SPRINT-002 |
| TODO-004 | Delete todo | Medium | Todo | SPRINT-002 |
```

## Sprint

`docs/project/sprints/SPRINT-001.md`

```md
# Sprint 001 — Todo Foundation

## Goal

Users can create and list todos.

## Tasks

- [ ] [[../tasks/TODO-001]]
- [ ] [[../tasks/TODO-002]]

## Definition of Done

- acceptance criteria satisfied
- build passes
- tests pass
- deterministic scope passes
- required gates (REVIEW/QA/VERIFY per classification) passed on the final tree
```

## Task

`docs/project/tasks/TODO-001.md`

```md
# TODO-001 — Create todo

Status: Todo
Priority: High
Sprint: SPRINT-001

## Goal

Allow users to create a todo.

## Acceptance Criteria

- POST `/api/v1/todos`
- title required
- description optional
- new todo incomplete
- persisted successfully
- returns HTTP 201
- tests pass

## Constraints

- no new packages
- no unrelated CRUD implementation
```

## Execution'a geçiş

Task dosyası run'ın task kaynağıdır (`task_source.type: local_markdown`); agent onun kabul kriterlerini ve kısıtlarını run'daki `TASK.md` sözleşmesine dönüştürür:

```text
docs/project/tasks/TODO-001.md   (kalıcı task kaynağı)
        ↓ normalize
.agents/runs/TODO-001/TASK.md    (geçici; freeze'den sonra değişmez)
```

Freeze'den sonra task dosyasının **sözleşme kısmı** değişirse `freshness` bloklar ve amendment + `refreeze` gerekir. Yalnız `**Status:**` değeri ve yayınlanan `## Completion Report` bloğu bookkeeping'dir; dosyanın konumu (ör. `in-progress/` → `done/`) yalnız `agent.sh task-source-relocate` ile kaydedilir.

## Başlatma ve bitirme

```text
Work on docs/project/tasks/TODO-001.md.
```
```text
docs/project/tasks/TODO-001.md task'ı üzerinde çalış.
```

Agent run'ı oluşturur, sınıflandırır, çalıştırır, completion report'u **bu task dosyasına** yayınlar (`markdown` adapter'ı) ve run'ı temizleyip durur. Task dosyasındaki `Status` ve sprint checkbox'ı uygulama scope'undan ayrı bookkeeping'dir. Aktivasyondaki `Status → In Progress` düzenlemesi baseline'dan **önce** yapılırsa baseline onu kullanıcı işi olarak kaydeder; freeze'den sonra scope dışı bir `docs/project/` düzenlemesi ise scope kontrolünde "unmapped path" olarak görünür (task kaynağı için tek istisna, completion report yayınlandıktan sonraki yazımdır). Bu yüzden bookkeeping'i ya baseline'dan önce/yayından hemen önce yap ya da ilgili yolları PLAN `scope:` içine al. Tamamlanmada `Status → Done` ve sprint checkbox'ı `[x]`.

## Wiki farkı

```text
docs/project/tasks/TODO-001.md
```

"ne yapacağız?" sorusunu cevaplar.

```text
.agents/runs/TODO-001/
```

"agent bu işi şu an nasıl güvenli yürütüyor?" sorusunu cevaplar; geçicidir ve task bitince silinir.

```text
docs/wiki/
```

"proje bu konu hakkında ne biliyor / neden böyle karar verdi?" sorusunu cevaplar.

## Execution role seçimi

Task kaynağı execution role'den bağımsızdır. Aynı task dosyasını Claude Code veya Codex normal `full_lifecycle` olarak baştan sona yürütebilir; `orchestrated` topology'de uygulama kodunu yalnız `implementation_worker` yazar. Worker task kaynağını veya frozen plan'ı değiştirmez; plan dışı bir yol ya da material karar gerektiğinde durur ve Orchestrator'a döner. Bu seçim repository config'ine bağlıdır, prompt'a yazılmaz.

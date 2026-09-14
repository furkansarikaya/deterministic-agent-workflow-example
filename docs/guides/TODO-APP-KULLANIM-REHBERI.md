# Deterministic Agent Workflow — Todo App Uygulama Rehberi

## Amaç

Bu rehber, `deterministic-agent-workflow-example` yapısını gerçek bir projeye nasıl adapte edeceğini uçtan uca gösterir.

Örnek uygulama:

**TodoFlow** — basit ama gerçekçi bir Todo uygulaması.

Bu örneğin amacı Todo uygulamasını öğretmek değil; aşağıdaki parçaların birlikte nasıl çalıştığını göstermektir:

- `AGENTS.md`
- `CLAUDE.md`
- `.agents/`
- `scripts/agent.sh`
- vibecosystem
- LLM Wiki
- Linear ile görev yönetimi
- Linear kullanmadan Markdown ile sprint/task yönetimi
- token/context tasarrufu
- task lifecycle
- CODE DONE / KNOWLEDGE DONE ayrımı

---

# 1. Örnek Proje

## TodoFlow

Kullanıcı:

- Todo oluşturabilir.
- Todo listesini görebilir.
- Todo'yu tamamlandı olarak işaretleyebilir.
- Todo silebilir.
- Todo'lara başlık ve açıklama girebilir.

Örnek stack:

```text
Backend: .NET 9 Web API
Database: PostgreSQL
ORM: EF Core
Tests: xUnit
API: REST
```

Bu rehberde özellikle backend üzerinden ilerleyeceğiz.

---

# 2. Golden Reference'tan Neleri Kopyalayacağız?

Yeni projen:

```text
TodoFlow/
├── AGENTS.md
├── CLAUDE.md
├── .agents/
├── scripts/
├── docs/
├── src/
└── tests/
```

Golden reference'tan kopyala:

```text
AGENTS.md
CLAUDE.md
.agents/
scripts/agent.sh
scripts/wiki-lint.sh
```

Sonra TodoFlow'a göre düzenle:

```text
AGENTS.md
CLAUDE.md
.agents/ENGINEERING.md
.agents/VERIFICATION.md
.agents/VIBECOSYSTEM.md
scripts/verify.sh
```

`EXAMPLE-001` gerçek projede zorunlu değildir.

İstersen referans olarak tut; istemiyorsan sil.

Ama:

```text
.agents/ACTIVE_RUN
```

başlangıçta boş kalmalıdır.

---

# 3. AGENTS.md Nasıl Düzenlenmeli?

Golden reference'taki deterministic protocol korunmalıdır.

Ama gerçek proje kendi domain ve repository kurallarını da eklemelidir.

TodoFlow için örnek:

```md
# TodoFlow agent instructions

This repository uses the shared deterministic agent control plane.

Follow `.agents/WORKFLOW.md` for task execution.

## Project

TodoFlow is a .NET 9 REST API for managing user todos.

## Repository structure

- `src/TodoFlow.Api` — HTTP/API layer
- `src/TodoFlow.Application` — use cases
- `src/TodoFlow.Domain` — domain model
- `src/TodoFlow.Infrastructure` — EF Core/PostgreSQL
- `tests/TodoFlow.UnitTests` — unit tests
- `tests/TodoFlow.IntegrationTests` — integration tests

## Project rules

- Target framework is .NET 9.
- Nullable reference types remain enabled.
- Do not introduce a new NuGet dependency unless TASK explicitly allows it.
- Controllers/endpoints must not contain business logic.
- Application use cases own orchestration.
- Domain invariants belong in Domain.
- Persistence implementation belongs in Infrastructure.
- Async I/O must accept CancellationToken where applicable.
- Public API changes require tests.
- Database schema changes require EF migration.
- Do not perform opportunistic refactoring outside frozen task scope.

## Verification

Use `./scripts/verify.sh`.

The task is not CODE DONE until required build/tests/scope/review gates pass.
```

## Önemli

`AGENTS.md`:

- shared workflow'u tekrar yazmamalı,
- projeye özel kuralları söylemeli,
- repository yapısını tarif etmeli,
- agent'ın yanlış layer'a kod yazmasını engellemeli.

Yani:

```text
.agents/*
    = ortak execution policy

AGENTS.md
    = bu repository'nin Codex/project adapter'ı
```

---

# 4. CLAUDE.md Nasıl Düzenlenmeli?

`CLAUDE.md`, `AGENTS.md` ile yarışmamalıdır.

Claude Code'a özel davranışları ve TodoFlow bağlamını eklemelidir.

Örnek:

```md
# TodoFlow Claude Code adapter

Follow `AGENTS.md` and the shared `.agents/` control plane.

## TodoFlow context

This is a .NET 9 layered Web API.

Primary solution:

- `TodoFlow.sln`
- `src/TodoFlow.Api`
- `src/TodoFlow.Application`
- `src/TodoFlow.Domain`
- `src/TodoFlow.Infrastructure`
- `tests/*`

Use project-specific rules from `AGENTS.md`.

## Claude-specific rules

- Do not use memory, recall, self-learning writes, prompt auto-improvement, or swarm during deterministic implementation unless explicitly permitted.
- Do not let persistent planning files override the frozen `.agents/runs/<TASK>/PLAN.md`.
- Use subagents only when allowed by the effective mode.
- Reviewer and verifier do not replace repository verification commands.
- Load context progressively; do not bulk-read `.agents/**`, `docs/wiki/**`, old runs, or the entire session history.

## Project capability preference

When useful and permitted:

- use TDD guidance for domain/application behavior,
- use code review after implementation,
- use verifier for acceptance checks,
- use security review only for security-sensitive changes.

Do not invoke broad orchestration for small TodoFlow tasks.
```

---

# 5. ENGINEERING.md Projeye Göre Düzenleme

Örnek:

```md
# TodoFlow engineering rules

## Architecture

Dependency direction:

Api → Application → Domain

Infrastructure implements interfaces required by Application/Domain.

Domain must not reference Infrastructure or ASP.NET Core.

## API

- REST endpoints use explicit request/response models.
- Validate external input before state mutation.
- Return appropriate HTTP status codes.
- Do not expose EF entities directly.

## Persistence

- PostgreSQL + EF Core.
- Use migrations for schema changes.
- Use `AsNoTracking()` for read-only queries where appropriate.
- Avoid N+1 query patterns.

## Testing

- Domain rules: unit tests.
- Application behavior: unit or focused integration tests.
- HTTP/database contracts: integration tests where relevant.

## Scope discipline

Do not rename unrelated types, reorganize directories, or upgrade packages unless required by TASK.
```

---

# 6. VERIFICATION.md ve verify.sh

`VERIFICATION.md` neyin kontrol edilmesi gerektiğini anlatır.

Örnek:

```md
# TodoFlow verification

Minimum verification:

1. `dotnet restore`
2. `dotnet build --no-restore`
3. `dotnet test --no-build`
4. `./scripts/agent.sh verify-freeze <TASK-ID>`
5. `./scripts/agent.sh verify-scope <TASK-ID>`

For DB changes:
- migration exists,
- model snapshot is consistent,
- relevant integration tests pass.
```

`scripts/verify.sh`:

```bash
#!/bin/sh
set -eu

dotnet restore
dotnet build --no-restore
dotnet test --no-build
```

Gerçek projede test projeleri veya solution yolu gerekiyorsa ona göre değiştir.

---

# 7. İlk Task'tan Önce

Kontrol et:

```bash
./scripts/agent.sh status
```

Beklenen:

```text
active_task=none
implementation_allowed=false
```

Bu normaldir.

Golden template'in resting state'i budur.

---

# 8. Linear Kullanarak Çalışma

Linear burada **iş yönetim sistemi**dir.

`.agents/runs` ise **execution contract/audit** alanıdır.

Bunlar birbirinin yerine geçmez.

```text
Linear
    ↓
hangi iş yapılacak?

.agents/runs/<TASK>
    ↓
bu iş agent tarafından nasıl güvenli/deterministik yapılacak?
```

---

# 9. Linear Yapısı

Örnek Team:

```text
TodoFlow
```

Örnek Project:

```text
TodoFlow MVP
```

Örnek Cycle:

```text
Sprint 1 — Todo Core
```

Issue'lar:

```text
TODO-1 Create todo
TODO-2 List todos
TODO-3 Complete todo
TODO-4 Delete todo
```

---

# 10. Linear Issue Örneği

## TODO-1 — Create todo endpoint

Description:

```md
Implement todo creation.

Acceptance Criteria:

- POST `/api/v1/todos`
- Request contains `title` and optional `description`
- Empty title is rejected
- Created todo defaults to incomplete
- Todo is persisted
- Response is HTTP 201
- Unit/integration tests cover success and invalid title

Constraints:

- No new NuGet packages
- Follow existing architecture
- Do not implement update/delete/list behavior in this task
```

Bu issue agent'ın TASK contract'ına dönüşür.

---

# 11. Linear Issue → Deterministic Run

Yeni run:

```text
.agents/runs/TODO-1/
├── TASK.md
├── EVIDENCE.md
├── PLAN.md
├── RUN.yaml
└── review/
```

`.agents/ACTIVE_RUN`:

```text
TODO-1
```

Sonra:

```bash
./scripts/agent.sh baseline TODO-1
```

## TASK.md

Linear issue'dan normalize edilir:

```md
# TODO-1 — Create todo endpoint

## Goal

Implement todo creation.

## Acceptance criteria

- AC-1: POST `/api/v1/todos` exists.
- AC-2: title is required.
- AC-3: description is optional.
- AC-4: a created todo starts incomplete.
- AC-5: todo is persisted.
- AC-6: API returns HTTP 201.
- AC-7: relevant tests pass.

## Constraints

- No new NuGet dependencies.
- Do not implement unrelated todo operations.
- Preserve current layered architecture.
```

Linear issue source/reference ID gerekiyorsa TASK'e referans olarak eklenebilir.

---

# 12. DISCOVER

Agent önce:

```text
TASK
↓
relevant source
↓
relevant tests
```

okur.

Örneğin:

```text
src/TodoFlow.Api
src/TodoFlow.Application
src/TodoFlow.Domain
src/TodoFlow.Infrastructure
tests/
```

ama yalnız task için ilgili dosyaları.

**Bütün repository'yi modele doldurmaz.**

Wiki ancak repo/testlerden cevap çıkmıyorsa kullanılır.

---

# 13. EVIDENCE.md Örneği

```md
# Evidence — TODO-1

## Repository

- Existing API uses Minimal APIs.
- Application layer uses command handlers.
- `TodoItem` does not yet exist.
- PostgreSQL DbContext lives in `TodoFlow.Infrastructure`.

## Relevant references

- `src/TodoFlow.Api/Program.cs`
- `src/TodoFlow.Application/...`
- `src/TodoFlow.Infrastructure/Persistence/AppDbContext.cs`
- `tests/TodoFlow.IntegrationTests/...`

## Constraints derived from evidence

- New endpoint must follow existing route-group style.
- Persistence must use the existing DbContext.
- No new package is required.

## Wiki

Not queried; current repository and tests were sufficient.
```

Burada özellikle:

> "Wiki kullanmadım."

demek gayet geçerli.

Wiki zorunlu değildir.

---

# 14. PLAN.md Örneği

```md
---
scope:
  - path: src/TodoFlow.Domain/Todos/TodoItem.cs
    criteria: [AC-2, AC-3, AC-4]
  - path: src/TodoFlow.Application/Todos/CreateTodo/*
    criteria: [AC-2, AC-3, AC-4, AC-5]
  - path: src/TodoFlow.Api/Endpoints/TodoEndpoints.cs
    criteria: [AC-1, AC-6]
  - path: src/TodoFlow.Infrastructure/Persistence/AppDbContext.cs
    criteria: [AC-5]
  - path: src/TodoFlow.Infrastructure/Persistence/Migrations/*
    criteria: [AC-5]
  - path: tests/TodoFlow.IntegrationTests/Todos/CreateTodoTests.cs
    criteria: [AC-1, AC-2, AC-4, AC-5, AC-6, AC-7]
---

# Plan

1. Add TodoItem domain model.
2. Add create-todo application use case.
3. Map persistence.
4. Add migration.
5. Expose POST endpoint.
6. Add focused tests.
7. Run verification.
```

Plan **uygulama scope'u**dur.

Workflow metadata'yı buraya eklemeye gerek yok.

---

# 15. Freeze

```bash
./scripts/agent.sh freeze TODO-1
./scripts/agent.sh verify-freeze TODO-1
```

Bundan sonra TASK/EVIDENCE/PLAN contract'tır.

Agent kafasına göre scope genişletemez.

---

# 16. Implement

Şimdi kod yazılır.

Deterministic mode:

- swarm açmaz,
- unrelated wiki okumaz,
- başka Linear issue'larına geçmez,
- fırsat bulmuşken refactor yapmaz,
- memory/self-learning ile scope değiştirmez.

---

# 17. Verify

```bash
./scripts/verify.sh
./scripts/agent.sh verify-freeze TODO-1
./scripts/agent.sh verify-scope TODO-1
```

Sonra review/verifier.

CODE DONE ancak tüm acceptance criteria karşılandıysa oluşur.

---

# 18. Linear Status Güncelleme

Örnek lifecycle:

```text
Linear Todo
    ↓
agent run created
    ↓
Linear In Progress
    ↓
CODE DONE
    ↓
Linear Done
```

İstersen review bekleyen takımda:

```text
Todo
→ In Progress
→ In Review
→ Done
```

kullanabilirsin.

Önemli kural:

> Linear status workflow state'in yerine geçmez.

Linear "Done" yazıyor diye `verify-scope` geçilmiş sayılmaz.

---

# 19. Linear Comment Örneği

Task bittiğinde issue'ya kısa execution summary yazılabilir:

```md
Implemented TODO-1.

Changed:
- Todo domain model
- CreateTodo application flow
- POST /api/v1/todos
- EF migration
- integration tests

Verification:
- dotnet build: PASS
- dotnet test: PASS
- deterministic freeze: PASS
- scope verification: PASS

No new dependencies added.
```

Bu comment audit için faydalıdır ama `.agents/runs/TODO-1/RESULT.md` yerine geçmez.

---

# 20. Linear Olmadan Markdown ile Yönetim

Linear istemiyorsan task management'ı repository içinde Markdown ile yapabilirsin.

Ama `.agents/runs` içine sprint backlog doldurma.

Ayır:

```text
project management
    → docs/project/

deterministic execution
    → .agents/runs/
```

Önerilen yapı:

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
        └── TODO-003.md
```

---

# 21. ROADMAP.md Örneği

```md
# TodoFlow Roadmap

## MVP

- Create todo
- List todos
- Complete todo
- Delete todo

## Later

- Due dates
- Tags
- Priority
- Authentication
- Shared lists
```

---

# 22. BACKLOG.md Örneği

```md
# Backlog

| ID | Title | Priority | Status | Sprint |
|---|---|---|---|---|
| TODO-001 | Create todo | High | Todo | SPRINT-001 |
| TODO-002 | List todos | High | Todo | SPRINT-001 |
| TODO-003 | Complete todo | High | Todo | SPRINT-002 |
| TODO-004 | Delete todo | Medium | Todo | SPRINT-002 |
```

---

# 23. SPRINT-001.md Örneği

```md
# Sprint 001 — Todo Foundation

## Goal

Users can create and view todos.

## Tasks

- [ ] [[../tasks/TODO-001]]
- [ ] [[../tasks/TODO-002]]

## Definition of Done

- Acceptance criteria satisfied
- Build passes
- Tests pass
- Deterministic scope verification passes
- Review/verifier complete
- Relevant wiki knowledge updated after CODE DONE
```

---

# 24. Markdown Task Örneği

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
- persistence succeeds
- returns HTTP 201
- tests pass

## Constraints

- no new packages
- no unrelated CRUD operations
```

Bu dosya project-management source olabilir.

Ama aktif execution başladığında bunun normalize edilmiş contract'ı yine:

```text
.agents/runs/TODO-001/TASK.md
```

olur.

Böylece backlog dosyasının sonradan değişmesi frozen execution contract'ı etkilemez.

---

# 25. Markdown Status Akışı

Task başlarken:

```text
Status: Todo
```

→

```text
Status: In Progress
```

CODE DONE sonrası:

```text
Status: Done
```

Sprint dosyasındaki checkbox da güncellenebilir.

Ama bunlar **Transaction A sırasında scope dışıysa** kafana göre düzenlenmez.

Task management metadata güncellemesinin hangi aşamada yapılacağı proje policy'sinde açıkça tanımlanmalıdır.

Basit tercih:

```text
task activation:
  status → In Progress

CODE DONE:
  status → Done
```

---

# 26. Linear ve Markdown Arasında Seçim

| İhtiyaç | Linear | Markdown |
|---|---:|---:|
| Takım çalışması | Çok iyi | Orta |
| Assignee | Çok iyi | Manuel |
| Sprint/Cycle | Yerleşik | Kendin yönetirsin |
| Filtreleme | Çok iyi | Git/search |
| Offline/Git-backed | Hayır | Evet |
| Basit solo proje | Gereğinden fazla olabilir | Çok iyi |
| Otomasyon | Çok iyi | Script gerekebilir |
| Deterministic run entegrasyonu | Referans ID ile | Dosya referansı ile |

Öneri:

```text
Solo / küçük open-source
→ Markdown yeterli

Takım / ürün / çok task
→ Linear daha iyi
```

---

# 27. LLM Wiki ile Project Management Aynı Şey Değildir

Üç alanı karıştırma:

```text
Linear veya docs/project
    = yapılacak işler

.agents/runs
    = aktif execution contract + proof

docs/wiki
    = proje bilgisi, kararlar, lessons, semantic memory
```

Örnek:

```text
"Complete todo endpoint yap"
    → task management

"Bu task hangi dosyaları değiştirebilir?"
    → deterministic run

"Neden soft delete yerine hard delete seçmiştik?"
    → wiki decision
```

---

# 28. CODE DONE Sonrası Wiki

Task tamamlanınca gerekli ise:

```text
/wiki-ingest
↓
wiki decisions / lessons / entities
↓
/wiki-lint
↓
KNOWLEDGE DONE
```

Her task wiki'ye büyük bir şey yazmak zorunda değildir.

Örneğin yalnız basit endpoint implementasyonu yeni reusable knowledge üretmediyse minimal update yeterlidir.

---

# 29. Token / Context Kullanımı

Amaç:

> determinism için tüm projeyi context'e yüklemek değildir.

Başlangıç:

```text
TASK
+ relevant repo files
+ relevant tests
```

Yetiyorsa devam et.

Yetmiyorsa:

```text
canonical docs
```

Yetmiyorsa:

```text
relevant wiki
```

## Okunmaması gerekenler

Küçük TODO-1 task'ında otomatik olarak:

```text
docs/wiki/** tamamı
.agents/** tamamı
eski runs tamamı
tüm Linear backlog
tüm sprintler
tüm session history
```

okunmamalıdır.

---

# 30. Reviewer Context

Reviewer'a ideal olarak:

```text
TASK
acceptance criteria
PLAN
relevant evidence references
git diff
relevant tests
```

verilir.

Tüm chat geçmişi verilmez.

---

# 31. Verifier Context

Daha küçük:

```text
acceptance criteria
verification commands
results
scope summary
relevant diff
```

---

# 32. TodoFlow Tam Akış Örneği

```text
Linear TODO-1
      |
      v
create .agents/runs/TODO-1
      |
      v
ACTIVE_RUN=TODO-1
      |
      v
agent.sh baseline TODO-1
      |
      v
DISCOVER
      |
      v
EVIDENCE
      |
      v
PLAN
      |
      v
FREEZE
      |
      v
IMPLEMENT
      |
      v
BUILD + TEST
      |
      v
VERIFY SCOPE
      |
      v
REVIEW + VERIFIER
      |
      v
CODE DONE
      |
      +------> Linear Done
      |
      v
/wiki-ingest
      |
      v
/wiki-lint
      |
      v
KNOWLEDGE DONE
```

Markdown kullanıyorsan ilk ve sondaki Linear yerine:

```text
docs/project/tasks/TODO-001.md
```

güncellenir.

---

# 33. Proje Kurulurken Bir Kerelik Checklist

- [ ] Golden control-plane dosyaları kopyalandı.
- [ ] `ACTIVE_RUN` boş.
- [ ] `AGENTS.md` proje yapısına göre düzenlendi.
- [ ] `CLAUDE.md` proje/Claude adapter olarak düzenlendi.
- [ ] `ENGINEERING.md` stack ve architecture kurallarını içeriyor.
- [ ] `VERIFICATION.md` gerçek build/test komutlarını içeriyor.
- [ ] `verify.sh` gerçek projeyi doğruluyor.
- [ ] vibecosystem capability isimleri kurulu profile göre doğrulandı.
- [ ] `docs/wiki` proje semantic-memory düzenine göre başlatıldı.
- [ ] Linear veya Markdown task management yaklaşımı seçildi.
- [ ] İlk task açılmadan implementation yapılmıyor.

---

# 34. Her Task İçin Checklist

- [ ] Task source belli: Linear issue veya Markdown task.
- [ ] Run oluşturuldu.
- [ ] `ACTIVE_RUN` ayarlandı.
- [ ] Baseline alındı.
- [ ] DISCOVER read-only tamamlandı.
- [ ] EVIDENCE concise.
- [ ] PLAN scope + AC mapping hazır.
- [ ] Freeze doğrulandı.
- [ ] Implementation yalnız scope içinde.
- [ ] Tests/build geçti.
- [ ] Scope geçti.
- [ ] Review/verifier tamamlandı.
- [ ] CODE DONE.
- [ ] Task manager status güncellendi.
- [ ] Gerekliyse wiki ingest/lint.
- [ ] KNOWLEDGE DONE.

---

# 35. Son Kural

Bu sistemin amacı agent'a daha fazla bürokrasi yaptırmak değildir.

İdeal davranış:

```text
küçük task
→ küçük context
→ küçük plan
→ küçük diff
→ net verification

büyük task
→ ihtiyaç kadar evidence
→ ihtiyaç kadar context
→ explicit scope
→ güçlü verification
```

Control plane işi kolaylaştırmıyorsa yanlış kullanılıyordur.

---

# 36. TodoFlow execution seçenekleri

TodoFlow task'ı üç şekilde yürütülebilir:

```text
Claude-only  → Claude full_lifecycle; VERIFY/REVIEW Claude'da
Codex-only   → Codex full_lifecycle; VERIFY/REVIEW Codex'te
Claude + Codex → Claude plan/freeze/VERIFY/REVIEW, Codex implementation_worker
```

Üçüncü modelde Codex frozen contract içindeki implementation'dan sonra
Claude'a döner. Codex worker PLAN'ı değiştirmez, review yapmaz veya CODE
DONE işaretlemez. Claude VERIFY/REVIEW fail bulursa aynı bounded scope
içinde focused fix için worker'ı yeniden çağırabilir.

Claude'dan Codex'e normal session devri ise worker delegation değildir:
Codex normal başlatıldıysa `full_lifecycle` olarak aynı run'a repository
state'ten devam eder.

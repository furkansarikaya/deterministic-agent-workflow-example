# TodoFlow — Markdown ile Task ve Sprint Yönetimi Örneği

## Hedef

Linear kullanmak istemeyen ekipler için Git-backed project management örneği.

Deterministic execution dosyaları ile project-management dosyalarını ayır.

```text
docs/project/
    = roadmap/backlog/sprint/task yönetimi

.agents/runs/
    = deterministic execution contract

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
- review/verifier complete
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

Task management dosyasından execution contract oluştur:

```text
docs/project/tasks/TODO-001.md
        ↓ normalize
.agents/runs/TODO-001/TASK.md
```

Bu önemli.

Sprint/task dosyası daha sonra değişebilir.

Frozen deterministic TASK bundan etkilenmemelidir.

## Başlatma

```text
TODO-001 Status: In Progress
```

`.agents/ACTIVE_RUN`:

```text
TODO-001
```

Sonra:

```bash
./scripts/agent.sh baseline TODO-001
```

Ve normal lifecycle.

## Bitirme

CODE DONE sonrası:

```text
TODO-001 Status: Done
```

`SPRINT-001.md`:

```md
- [x] [[../tasks/TODO-001]]
```

Task management güncellemelerinin application implementation scope'u ile karışmaması için proje policy'sinde ne zaman güncellenecekleri açıkça belirlenmelidir.

Basit yaklaşım:

```text
activation transaction:
    status → In Progress

completion transaction:
    status → Done
    sprint checkbox → completed
```

## Wiki farkı

```text
docs/project/tasks/TODO-001.md
```

"ne yapacağız?" sorusunu cevaplar.

```text
.agents/runs/TODO-001/
```

"agent bu işi hangi contract ile yaptı?" sorusunu cevaplar.

```text
docs/wiki/
```

"proje bu konu hakkında ne biliyor / neden böyle karar verdi?" sorusunu cevaplar.

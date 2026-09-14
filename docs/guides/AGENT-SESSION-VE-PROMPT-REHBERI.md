# Agent Session ve Prompt Rehberi

Bu rehber, deterministic agent workflow kullanırken Claude Code ve Codex ile bir task'ın nasıl yürütüleceğini anlatır.

Desteklenen temel kullanım modelleri:

1. **Claude-only**
2. **Codex-only**
3. **Claude orchestrator + Codex implementation worker**
4. **Cross-agent full-lifecycle resume** — örneğin Claude ile başlayıp Codex ile aynı run'a devam etmek

Linear kullanan ve kullanmayan projeler için aynı temel model geçerlidir.

---

## 1. Temel model

Ana kural:

> **1 task = 1 deterministic run.**

Tercih edilen kullanım:

> **1 task = 1 ana Claude/Codex session.**

Ancak session workflow state'i değildir. Bir session kapanabilir, başka bir session açılabilir, hatta task aynı deterministic run üzerinden başka bir agent tarafından sürdürülebilir.

Kalıcı state chat geçmişinde değil şuralardadır:

- Git ve mevcut repository state'i
- `.agents/runs/<TASK-ID>/`
- `TASK.md`
- `EVIDENCE.md`
- `PLAN.md`
- `RUN.yaml`
- gerektiğinde `RESULT.md`
- canonical proje dokümantasyonu
- gerektiğinde LLM Wiki

Bu nedenle Plan, Implement, Verify ve Review için kullanıcının ayrı ayrı manuel session açması gerekmez.

```text
TASK
  ↓
ACTIVATE RUN
  ↓
BASELINE
  ↓
DISCOVER
  ↓
EVIDENCE
  ↓
PLAN
  ↓
FREEZE
  ↓
IMPLEMENT
  ↓
VERIFY
  ↓
REVIEW
  ↓
CODE DONE
  ↓
KNOWLEDGE TRANSACTION
  ↓
KNOWLEDGE DONE
  ↓
STOP
```

Normal happy-path'te agent bu state'ler arasında kullanıcıdan rutin onay istemeden ilerlemelidir.

---

## 2. Execution role modeli

Agent identity ile execution role aynı şey değildir.

Canonical roller:

```text
full_lifecycle
implementation_worker
```

Default davranış:

```text
Normal Claude invocation
→ full_lifecycle

Normal Codex invocation
→ full_lifecycle

Explicit bounded worker invocation
→ implementation_worker
```

Yani:

```text
Claude-only
→ Claude = full_lifecycle

Codex-only
→ Codex = full_lifecycle

Claude + Codex
→ Claude = lifecycle owner / orchestrator
→ Codex = implementation_worker
```

Önemli:

> **Codex global olarak implementation-only değildir.**

Codex yalnızca açıkça `implementation_worker` olarak çağrıldığında bounded worker olur.

---

## 3. Claude-only kullanım

Claude tek başına bütün workflow'u yürütebilir:

```text
Claude
  ↓
TASK
DISCOVER
EVIDENCE
PLAN
FREEZE
IMPLEMENT
VERIFY
REVIEW
CODE DONE
KNOWLEDGE
STOP
```

### Linear — Claude-only günlük prompt

```text
Work on Linear issue TODO-123.

Follow this repository's AGENTS.md, CLAUDE.md, and deterministic workflow.

Use TODO-123 as the task identity and execute the complete task lifecycle autonomously in full_lifecycle mode.

Create or resume the corresponding deterministic run, capture the baseline when required, and proceed through DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE, and the required knowledge transaction until KNOWLEDGE DONE.

Use progressive disclosure. Do not load unrelated repository files, wiki pages, historical runs, Linear issues, or session history.

Do not redo completed workflow states when resuming an existing run.

Do not ask me to approve routine workflow transitions. Ask only when there is:
- a material requirement ambiguity,
- a conflict between authoritative evidence,
- an irreversible or destructive action requiring approval,
- or a material scope expansion that cannot be resolved from the task and repository.

Do not perform opportunistic improvements or unrelated refactoring.

When the task reaches its required final state, update the task-management state if permitted, give me a concise final report with verification evidence, and stop.

Do not start another task.
```

### Türkçe karşılığı

```text
Linear'daki TODO-123 issue'su üzerinde çalış.

Bu repository'nin AGENTS.md, CLAUDE.md ve deterministic workflow kurallarını takip et.

TODO-123'ü task identity olarak kullan ve full_lifecycle modunda tüm task lifecycle'ını otonom yürüt.

İlgili deterministic run'ı oluştur veya devam et; gerektiğinde baseline al ve DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE ve gerekli knowledge transaction aşamalarını KNOWLEDGE DONE'a kadar ilerlet.

Progressive disclosure kullan. İlgisiz repository dosyalarını, wiki sayfalarını, historical run'ları, Linear issue'larını veya session geçmişini yükleme.
Tamamlanmış workflow state'lerini tekrar yapma. Rutin geçişler için onay isteme.

Yalnız material requirement belirsizliği, çözülemeyen authoritative evidence çatışması, onay gerektiren irreversible işlem veya çözülemeyen material scope genişlemesinde dur.

İzin varsa task-management state'ini güncelle, verification evidence içeren kısa final rapor ver ve dur. Başka task başlatma.
```

### Markdown task — Claude-only günlük prompt

```text
Work on project task TODO-001 defined in docs/project/tasks/TODO-001.md.

Follow this repository's AGENTS.md, CLAUDE.md, and deterministic workflow.

Use TODO-001 as the deterministic task identity and execute the complete task lifecycle autonomously in full_lifecycle mode.

Create or resume the corresponding run and continue through DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE, and the required knowledge transaction until KNOWLEDGE DONE.

Treat the project task file as the task-management source and normalize the executable contract into the deterministic run according to repository policy.

Use progressive disclosure. Do not load unrelated backlog items, sprint documents, wiki pages, historical runs, or repository files.

Do not ask for approval between routine workflow states.

Stop only for a material ambiguity, authoritative evidence conflict, approval-required irreversible action, or material scope expansion that cannot be resolved from repository evidence.

When complete, update the Markdown task/sprint status if repository policy permits it, report the verification evidence and final state, and stop.

Do not start another backlog item.
```

### Türkçe karşılığı

```text
docs/project/tasks/TODO-001.md içindeki TODO-001 proje task'ı üzerinde çalış.

Bu repository'nin AGENTS.md, CLAUDE.md ve deterministic workflow kurallarını takip et.

TODO-001'i deterministic task identity olarak kullan ve full_lifecycle modunda lifecycle'ın tamamını otonom yürüt.

Run'ı oluştur veya devam et; DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE ve gerekli knowledge transaction aşamalarını KNOWLEDGE DONE'a kadar sürdür.

Proje task dosyasını task-management source olarak kullan; executable contract'ı repository policy'sine göre deterministic run'a normalize et.
Progressive disclosure kullan, ilgisiz backlog/sprint/wiki/historical run context'ini yükleme ve rutin geçişlerde onay isteme.

Yalnız material belirsizlik, evidence çatışması, onay gerektiren irreversible işlem veya çözülemeyen scope genişlemesinde dur. İzin varsa Markdown task/sprint state'ini güncelle, verification evidence ile rapor ver ve dur.
```

---

## 4. Codex-only kullanım

Codex de normal başlatıldığında `full_lifecycle` agent'tır.

```text
Codex
  ↓
TASK
DISCOVER
EVIDENCE
PLAN
FREEZE
IMPLEMENT
VERIFY
REVIEW
CODE DONE
KNOWLEDGE
STOP
```

Claude zorunlu değildir.

### Linear — Codex-only günlük prompt

```text
Work on Linear issue TODO-123 in full_lifecycle mode.

Follow AGENTS.md and the repository deterministic workflow.

Use TODO-123 as the task identity.

Create or resume the corresponding deterministic run and execute the complete lifecycle autonomously through DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE, and the required knowledge transaction until KNOWLEDGE DONE.

Use progressive disclosure.
Do not redo completed workflow states.
Do not perform unrelated refactoring or opportunistic improvements.
Do not ask for approval for routine workflow transitions.

Ask only for a genuine material ambiguity, unresolved authoritative evidence conflict, approval-required irreversible action, or unavoidable material scope expansion.

When complete, report the verification evidence and final state, update task-management state only if permitted, and stop.

Do not start another task.
```

### Türkçe karşılığı

```text
Linear'daki TODO-123 issue'su üzerinde full_lifecycle modunda çalış.

AGENTS.md ve repository deterministic workflow'unu takip et. TODO-123'ü task identity olarak kullan.

İlgili run'ı oluştur veya devam et; DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE ve gerekli knowledge transaction aşamalarını KNOWLEDGE DONE'a kadar otonom yürüt.

Progressive disclosure kullan. Tamamlanmış workflow state'lerini tekrar yapma, ilgisiz refactor yapma ve rutin geçişlerde onay isteme.

Yalnız gerçek material belirsizlik, çözülemeyen evidence çatışması, onay gerektiren irreversible işlem veya kaçınılmaz scope genişlemesinde sor. Tamamlanınca verification evidence ve final state'i raporla, izin varsa task-management state'ini güncelle ve dur.
```

---

# 5. Claude orchestrator + Codex implementation worker

Bu modelde Claude lifecycle owner olarak kalır.

Akış:

```text
Claude
  TASK
  DISCOVER
  EVIDENCE
  PLAN
  FREEZE
     ↓
     ↓ explicit bounded dispatch
     ↓
Codex
  implementation_worker
  IMPLEMENT ONLY
     ↓
     ↓ return control
     ↓
Claude
  VERIFY
  REVIEW
  CODE DONE
  KNOWLEDGE
  STOP
```

Claude şu aşamaların sahibidir:

- task çözümleme
- baseline
- DISCOVER
- EVIDENCE
- PLAN
- freeze
- Codex'e implementation dispatch
- VERIFY
- REVIEW
- bounded fix kararı
- CODE DONE
- delivery authorization
- knowledge transaction

Codex worker yalnızca:

- frozen TASK/EVIDENCE/PLAN'ı tüketir
- PLAN-authorized application scope içinde implement eder
- focused implementation check'leri çalıştırabilir
- implementation sonucu changed path'leri raporlar
- control'ü Claude'a geri verir

Worker şunları yapmaz:

- DISCOVER'ı tekrar etmez
- EVIDENCE oluşturmaz/değiştirmez
- PLAN oluşturmaz/değiştirmez
- freeze/refreeze yapmaz
- VERIFY/REVIEW yapmaz
- VERIFIED/REVIEWED/CODE_DONE işaretlemez
- delivery yapmaz
- wiki/knowledge transaction yapmaz
- başka agent çağırmaz
- recursive Codex delegation yapmaz

---

## 6. Claude orchestrator olarak nasıl başlatılır?

Bu, önceki rehberde eksik kalan en önemli prompttur.

Bu prompt Claude Code'a verilir.

Claude task'ın orchestration'ını kendisi yürütür; implementation aşamasına gelince Codex'i explicit `implementation_worker` olarak çağırır; Codex döndükten sonra Claude VERIFY/REVIEW/CODE DONE akışını devam ettirir.

### Linear — Claude orchestrator tek-shot prompt

```text
Work on Linear issue TODO-123 as the lifecycle orchestrator.

Follow this repository's AGENTS.md, CLAUDE.md, and deterministic workflow.

Use TODO-123 as the task identity and own the complete deterministic lifecycle.

Create or resume the corresponding run, capture the baseline when required, and perform DISCOVER, EVIDENCE, PLAN, and freeze yourself.

For application implementation, explicitly delegate ONLY the implementation phase to Codex using the repository's implementation_worker role.

Do not ask Codex to rerun discovery, evidence gathering, planning, freezing, review, delivery, or knowledge work.

When Codex returns, resume ownership of the same deterministic run yourself.

Perform VERIFY and REVIEW yourself according to repository policy.

If verification or review requires a bounded implementation fix, create a focused correction instruction and dispatch Codex again only as implementation_worker. Codex must fix only the authorized implementation scope and return control to you.

You remain responsible for:
- DISCOVER,
- EVIDENCE,
- PLAN,
- freeze,
- verification,
- review,
- bounded-fix decisions,
- CODE DONE,
- delivery authorization,
- and the required knowledge transaction.

Do not let the implementation worker become the workflow orchestrator.
Do not let the worker delegate to another agent.
Do not let the worker mark VERIFIED, REVIEWED, or CODE_DONE.

Use repository state as the persistent source of truth. Do not depend on Codex having access to this Claude conversation.

Use progressive disclosure. Do not load unrelated repository files, wiki pages, historical runs, Linear issues, or session history.

Do not redo completed workflow states when resuming an existing run.

Do not ask me to approve routine workflow transitions. Ask only when there is:
- a material requirement ambiguity,
- a conflict between authoritative evidence,
- an irreversible or destructive action requiring approval,
- or a material scope expansion that cannot be resolved from the task and repository.

Do not perform opportunistic improvements or unrelated refactoring.

Continue autonomously through the required workflow until KNOWLEDGE DONE.

When complete, update task-management state only if permitted, give me a concise final report including verification evidence and any Codex implementation handoffs, and stop.

Do not start another task.
```

### Türkçe karşılığı

```text
Linear'daki TODO-123 issue'su üzerinde lifecycle orchestrator olarak çalış.

Bu repository'nin AGENTS.md, CLAUDE.md ve deterministic workflow kurallarını takip et.

TODO-123'ü task identity olarak kullan ve deterministic lifecycle'ın tamamının sahibi sen ol.

İlgili run'ı oluştur veya mevcutsa devam ettir; gerektiğinde baseline al; DISCOVER, EVIDENCE, PLAN ve freeze aşamalarını kendin yürüt.

Application implementation aşamasında YALNIZCA implementation işini repository'nin implementation_worker rolünü kullanarak Codex'e explicit olarak delege et.

Codex'ten discovery, evidence, planning, freeze, review, delivery veya knowledge işlemlerini tekrar yapmasını isteme.

Codex implementation'ı tamamlayıp döndüğünde aynı deterministic run'ın lifecycle ownership'ini tekrar sen sürdür.

VERIFY ve REVIEW aşamalarını repository policy'sine göre kendin yürüt.

Verification veya review sonucunda bounded bir implementation fix gerekiyorsa focused bir correction instruction oluştur ve Codex'i yalnız implementation_worker olarak tekrar çağır. Codex yalnız yetkili implementation scope içinde fix yapmalı ve control'ü sana geri vermeli.

Şu aşamaların sahibi her zaman sensin:
- DISCOVER,
- EVIDENCE,
- PLAN,
- freeze,
- verification,
- review,
- bounded-fix kararları,
- CODE DONE,
- delivery authorization,
- gerekli knowledge transaction.

Implementation worker'ın workflow orchestrator'a dönüşmesine izin verme.
Worker'ın başka bir agent delege etmesine izin verme.
Worker'ın VERIFIED, REVIEWED veya CODE_DONE işaretlemesine izin verme.

Persistent source of truth olarak repository state'i kullan. Codex'in bu Claude conversation'ına erişebildiğini varsayma.

Progressive disclosure kullan. İlgisiz repository dosyalarını, wiki sayfalarını, historical run'ları, Linear issue'larını veya session geçmişini yükleme.

Mevcut bir run'a devam ediyorsan tamamlanmış workflow state'lerini tekrar yapma.

Rutin workflow geçişleri için benden onay isteme. Yalnızca şu durumlarda sor:
- önemli bir requirement belirsizliği,
- authoritative evidence kaynakları arasında çatışma,
- onay gerektiren geri döndürülemez/destructive işlem,
- task ve repository'den çözülemeyen önemli bir scope genişlemesi.

Fırsat bulmuşken iyileştirme veya ilgisiz refactor yapma.

Gerekli workflow'u otonom şekilde KNOWLEDGE DONE'a kadar yürüt.

Tamamlandığında, izin veriliyorsa task-management state'ini güncelle; verification evidence ve yapılan Codex implementation handoff'larını içeren kısa bir final rapor ver ve dur.

Başka bir task'a geçme.
```

---

## 7. Markdown task — Claude orchestrator tek-shot prompt

```text
Work on project task TODO-001 defined in docs/project/tasks/TODO-001.md as the lifecycle orchestrator.

Follow AGENTS.md, CLAUDE.md, and the repository deterministic workflow.

Use TODO-001 as the deterministic task identity.

Create or resume the corresponding run.
Perform baseline, DISCOVER, EVIDENCE, PLAN, and freeze yourself.

Delegate ONLY application implementation to Codex using the explicit implementation_worker role.

Codex must consume the already-frozen TASK, EVIDENCE, and PLAN, implement only the authorized application scope, perform only focused implementation checks, and return control to you.

After Codex returns, perform VERIFY and REVIEW yourself.

If a bounded implementation correction is required, dispatch Codex again only as implementation_worker with a focused fix instruction.

Do not let Codex perform planning, refreeze, review, CODE DONE, delivery, knowledge operations, or recursive delegation.

You remain the lifecycle owner until the deterministic run reaches its required final state.

Use progressive disclosure.
Do not redo completed states.
Do not perform unrelated refactoring.
Do not ask for routine workflow approvals.

When complete, update the Markdown task/sprint state only if repository policy permits it, report verification evidence and the final state, and stop.

Do not start another backlog item.
```

### Türkçe karşılığı

```text
docs/project/tasks/TODO-001.md içindeki TODO-001 task'ı üzerinde lifecycle orchestrator olarak çalış.

AGENTS.md, CLAUDE.md ve repository deterministic workflow'unu takip et. TODO-001 deterministic task identity'sidir.

Run'ı oluştur veya devam et. Baseline, DISCOVER, EVIDENCE, PLAN ve freeze'i kendin yürüt.

Yalnız application implementation'ını Codex'e explicit implementation_worker rolüyle delege et. Codex frozen TASK/EVIDENCE/PLAN'ı kullanmalı, yalnız yetkili scope'u uygulamalı, odaklı check'ler çalıştırmalı ve sana dönmelidir.

Codex döndükten sonra VERIFY ve REVIEW'i kendin yap. Bounded fix gerekirse Codex'i yalnız focused fix instruction ile worker olarak tekrar çağır.

Codex'in planning, refreeze, review, CODE DONE, delivery, knowledge işlemi veya recursive delegation yapmasına izin verme. Lifecycle owner olarak required final state'e kadar sen kal.

Progressive disclosure kullan; tamamlanmış state'leri tekrar yapma, ilgisiz refactor/approval döngüsü oluşturma. İzin varsa Markdown task/sprint state'ini güncelle, verification evidence ile rapor ver ve dur.
```

---

## 8. Codex implementation worker dispatch prompt

Bu prompt orchestrator tarafından Codex'e verilir.

```text
Act as the implementation worker for the currently active deterministic task.

You are a bounded implementation worker, not the workflow orchestrator.

Consume the already-frozen TASK, EVIDENCE, and PLAN.

Validate only the minimum persisted repository/run state necessary to ensure you are implementing the correct frozen task.

Implement only the PLAN-authorized application scope.

You MAY:
- read the active run,
- read the frozen TASK/EVIDENCE/PLAN,
- inspect task-relevant repository files,
- inspect current Git state,
- modify PLAN-authorized application paths,
- run focused implementation-level checks,
- fix failures directly caused by your implementation when the fix remains inside frozen scope.

You MUST NOT:
- redo DISCOVER,
- create or modify EVIDENCE,
- create or modify PLAN,
- amend or refreeze,
- expand scope,
- perform REVIEW,
- mark VERIFIED,
- mark REVIEWED,
- mark CODE_DONE,
- perform delivery,
- commit or push,
- update external task-management systems,
- perform wiki or knowledge operations,
- invoke another implementation worker,
- delegate to another agent,
- recursively invoke Codex,
- start another task.

If implementation requires a material planning decision, a path outside the frozen PLAN, conflicting authoritative evidence, or an unauthorized destructive/irreversible action:

STOP and return the blocker to the orchestrator.

Do not amend the contract yourself.

When implementation is complete:
1. report the exact changed paths,
2. report the focused implementation checks you ran and their results,
3. report any caveats,
4. return control to the orchestrator.

Stop after returning the implementation result.
```

### Türkçe karşılığı

```text
Mevcut aktif deterministic task için implementation worker olarak davran.

Sen workflow orchestrator değil, bounded implementation worker'sın.
Önceden freeze edilmiş TASK, EVIDENCE ve PLAN'ı kullan.
Doğru frozen task üzerinde çalıştığını anlamak için yalnız minimum persisted repository/run state'ini doğrula.

Yalnız PLAN tarafından yetkili application scope'u uygula.

Yapabileceklerin: active run ve frozen contract'ı okumak, task-relevant repository/Git state'i incelemek, yetkili application path'lerini değiştirmek, focused implementation check'leri çalıştırmak ve frozen scope içindeki implementation kaynaklı hataları düzeltmektir.

DISCOVER, EVIDENCE, PLAN, amendment/refreeze, scope genişletme, REVIEW, VERIFIED/REVIEWED/CODE DONE, delivery, commit/push, external task update, wiki/knowledge, başka worker çağırma veya delegation yapma.

Material planning kararı, PLAN dışı path, conflicting authoritative evidence veya yetkisiz destructive/irreversible işlem gerekirse DUR ve blocker'ı orchestrator'a döndür. Contract'ı kendin değiştirme.

Bitince changed path'leri, focused check sonuçlarını ve caveat'leri raporla; control'ü orchestrator'a döndür ve dur.
```

---

## 9. Bounded fix — Claude → Codex prompt

Claude VERIFY veya REVIEW sırasında problem bulursa full workflow'u Codex'e devretmez.

Sadece focused fix gönderir:

```text
Act as the implementation_worker for the currently active deterministic task.

The orchestrator's verification/review found the following implementation issue:

<INSERT EXACT FAILURE / REVIEW FINDING>

Fix ONLY this issue within the existing frozen TASK, EVIDENCE, PLAN, and authorized application scope.

Do not redo discovery, evidence, planning, or freezing.
Do not expand scope.
Do not perform review.
Do not mark VERIFIED, REVIEWED, or CODE_DONE.
Do not perform delivery or knowledge operations.
Do not delegate to another agent.

Run only the focused implementation checks necessary for this correction.

If the fix requires a material plan/scope change, stop and return the blocker instead of changing the frozen contract.

When the fix is complete, report:
- changed paths,
- exact correction made,
- focused checks and results,
- any blocker/caveat,

then return control to the orchestrator and stop.
```

### Türkçe karşılığı

```text
Mevcut aktif deterministic task için implementation_worker olarak davran.

Orchestrator'un verification/review sırasında bulduğu issue:

<TAM HATA / REVIEW BULGUSU>

Yalnız bu issue'yu mevcut frozen TASK, EVIDENCE, PLAN ve yetkili application scope içinde düzelt.

Discovery, evidence, planning veya freeze'i tekrar yapma. Scope genişletme, review, VERIFIED/REVIEWED/CODE DONE, delivery, knowledge veya delegation yapma.

Fix material plan/scope değişikliği gerektirirse frozen contract'ı değiştirmek yerine dur ve blocker'ı döndür.

Bitince changed path'leri, düzeltmeyi, focused check sonuçlarını ve caveat'leri raporla; control'ü orchestrator'a döndür ve dur.
```

Akış:

```text
Claude VERIFY / REVIEW
        ↓
       FAIL
        ↓
Claude focused fix instruction
        ↓
Codex implementation_worker
        ↓
implementation-only fix
        ↓
return
        ↓
Claude VERIFY / REVIEW
```

Bu **bounded QA correction loop**'tur.

Bu recursive orchestration değildir.

Worker kendi kendini yeniden çağırmaz. Yeni worker invocation kararı orchestrator'a aittir.

---

# 10. Resume ile delegation aynı şey değildir

Bu iki senaryo karıştırılmamalıdır.

## A. Cross-agent full-lifecycle resume

Claude session'ı kapanır veya limiti biter:

```text
Claude
full_lifecycle
    ↓
session ends
    ↓
Codex normal açılır
    ↓
Codex = full_lifecycle
    ↓
aynı deterministic run'a devam eder
```

Burada Codex **worker değildir**.

### Resume prompt

```text
Resume the currently active deterministic task in full_lifecycle mode.

Follow AGENTS.md and the repository deterministic workflow.

Resolve the active run from repository state.

Validate only the persisted state required to safely continue, inspect the frozen TASK/EVIDENCE/PLAN and current Git state, determine the last valid workflow state, and continue autonomously from there.

Do not recreate or redo completed workflow states.

Do not rely on previous chat history.

Continue until the task reaches its required final state or a genuine user decision is required.
```

### Türkçe karşılığı

```text
Mevcut aktif deterministic task'a full_lifecycle modunda devam et.

AGENTS.md ve repository deterministic workflow'unu takip et. Active run'ı repository state'ten çöz.

Güvenli devam için yalnız gerekli persisted state'i doğrula; frozen TASK/EVIDENCE/PLAN ve current Git state'i incele, son geçerli workflow state'ini belirle ve buradan otonom devam et.

Tamamlanmış workflow state'lerini yeniden oluşturma veya tekrar yapma. Önceki chat geçmişine dayanma.

Task required final state'e ulaşana ya da gerçek bir user kararı gerekene kadar devam et.
```

---

## B. Delegated implementation

Claude session devam eder:

```text
Claude full_lifecycle/orchestrator
        ↓
Codex explicit implementation_worker
        ↓
Codex implementation
        ↓
return
        ↓
Claude VERIFY / REVIEW / ...
```

Burada Claude lifecycle owner olmaya devam eder.

Özet:

```text
Normal Codex invocation
→ full_lifecycle

Explicit worker invocation
→ implementation_worker
```

---

# 11. Session yarıda kapanırsa

Session'ın kapanması run'ın kaybolduğu anlamına gelmez.

Örnek:

```text
TODO-123
├─ BASELINE ✓
├─ DISCOVER ✓
├─ EVIDENCE ✓
├─ PLAN ✓
├─ FREEZE ✓
└─ IMPLEMENT %40
```

Yeni Claude/Codex session'ı mevcut state'i repository'den çözebilmelidir.

> **Chat history convenience'tır; source of truth değildir.**

Aynı deterministic run başka agent tarafından sürdürülebilir.

---

# 12. Plan için ayrı Claude session gerekir mi?

Hayır.

`DISCOVER → EVIDENCE → PLAN → IMPLEMENT` aynı ana session içinde yürüyebilir.

Claude Code'un **Plan Mode** özelliği ile deterministic workflow içindeki `PLAN.md` aynı şey değildir.

```text
Claude Plan Mode
= geçici agent interaction/behavior mode

.agents/runs/<TASK-ID>/PLAN.md
= frozen deterministic implementation contract
```

Claude Plan Mode kullanılabilir ama zorunlu değildir.

Orchestrator + Codex modelinde de Claude:

```text
DISCOVER
→ EVIDENCE
→ PLAN
→ FREEZE
```

yaptıktan sonra aynı Claude session'ında Codex worker dispatch eder ve dönüşte workflow'a devam eder.

---

# 13. Reviewer ve verifier ayrı session mı?

Kullanıcının manuel olarak ayrı Claude terminal/session açması gerekmez.

Reviewer ve verifier gerektiğinde bounded subagent/context olarak çalışabilir.

```text
                    ┌─ code reviewer
Main task session ──┤
                    └─ verifier
```

Reviewer context'i mümkün olduğunca bounded olmalıdır:

- TASK ve acceptance criteria
- frozen PLAN
- ilgili evidence referansları
- task diff'i
- ilgili test sonuçları

Verifier'ın context'i mümkünse daha da küçük tutulmalıdır.

Reviewer/verifier gerçek repository verification komutlarının yerine geçmez.

Claude orchestrator + Codex worker modelinde review/verifier ownership Claude tarafında kalır.

---

# 14. Worker blocker davranışı

Worker aşağıdaki gibi material bir durum görürse kendisi karar verip contract'ı değiştirmez:

- PLAN dışı application path gerekiyor
- yeni material API kararı gerekiyor
- architecture kararı gerekiyor
- authoritative evidence çatışıyor
- destructive/irreversible işlem gerekiyor
- frozen contract güvenli implementation'a izin vermiyor

Davranış:

```text
STOP
↓
REPORT BLOCKER
↓
RETURN TO ORCHESTRATOR
```

Yanlış davranış:

```text
PLAN değiştir
→ refreeze
→ scope genişlet
→ implementasyona devam et
```

---

# 15. CODE DONE ve KNOWLEDGE DONE

Kodun tamamlanması ile proje bilgisinin güncellenmesi iki ayrı transaction'dır.

```text
Transaction A

TASK
 ↓
DISCOVER
 ↓
EVIDENCE
 ↓
PLAN
 ↓
IMPLEMENT
 ↓
VERIFY
 ↓
REVIEW
 ↓
CODE DONE
```

```text
Transaction B

CODE RESULT
 ↓
factual summary
 ↓
/wiki-ingest
 ↓
relevant decisions / lessons
 ↓
/wiki-lint
 ↓
KNOWLEDGE DONE
```

Deterministic implementation sırasında wiki read-only'dir.

> **Task kendi geçmişini değiştiremez. Ama bittikten sonra gelecek task'lar için geçmiş olur.**

Claude orchestrator + Codex worker modelinde knowledge transaction orchestrator tarafında kalır.

Codex worker wiki veya knowledge transaction yapmaz.

---

# 16. Agent ne zaman kullanıcıya soru sormalı?

Workflow state geçişleri soru sebebi değildir.

Yanlış:

> PLAN tamamlandı. Implementation'a geçeyim mi?

Yanlış:

> Codex implementation'ı tamamladı. Verify'a geçeyim mi?

Workflow izin veriyorsa orchestrator devam etmelidir.

Agent yalnızca şu durumlarda durmalıdır:

- önemli requirement belirsizliği
- authoritative evidence kaynakları arasında çözülemeyen çatışma
- geri döndürülemez/destructive ve onay gerektiren işlem
- task/repository evidence ile çözülemeyen material scope genişlemesi

---

# 17. Task bittikten sonra aynı session'da yeni task?

Tercih edilen kullanım: **hayır**.

```text
Session #1
└─ TODO-123
   └─ DONE

Session #2
└─ TODO-124
   └─ DONE
```

Bu determinism zorunluluğundan çok context hijyenidir.

> **1 task = 1 session bir kullanım tercihi; 1 task = 1 deterministic run sistem kuralıdır.**

Claude orchestrator kullanılıyorsa da yeni Linear/Markdown task için yeni ana Claude session tercih edilir.

---

# 18. Token ve context davranışı

Deterministic workflow tüm control plane'i her task'ta modele yüklemek anlamına gelmez.

Progressive disclosure uygulanmalıdır.

Başlangıçta:

```text
TASK
+ ilgili repository code
+ ilgili tests
```

yeterliyse wiki açılmaz.

Gerektiğinde:

```text
index
 ↓
ilgili decision
 ↓
ilgili lesson
 ↓
gerekirse source
```

Yüklenmemesi gerekenler:

- tüm `.agents/**`
- tüm `docs/wiki/**`
- eski run'ların tamamı
- bütün Linear backlog'u
- bütün sprint geçmişi
- gereksiz conversation history
- task ile ilgisiz capability/skill dokümanları

> **Determinism must not require loading the entire control plane or knowledge base into model context.**

Bu özellikle orchestrator + worker kullanımında önemlidir:

Codex'e Claude'un bütün session geçmişi gönderilmez.

Codex şunları tüketir:

```text
frozen TASK
+ relevant EVIDENCE
+ frozen PLAN
+ task-relevant repository state
```

---

# 19. Hangi modeli ne zaman kullanacağım?

## Sadece Claude

```text
Claude'u normal aç
→ full_lifecycle
→ tek-shot task promptu ver
```

## Sadece Codex

```text
Codex'i normal aç
→ full_lifecycle
→ tek-shot task promptu ver
```

## Claude planlasın/review etsin, Codex kod yazsın

```text
Claude'u normal aç
→ Claude orchestrator promptu ver
→ Claude DISCOVER/EVIDENCE/PLAN/FREEZE
→ Claude Codex'i implementation_worker olarak çağırır
→ Codex implement eder ve döner
→ Claude VERIFY/REVIEW
→ gerekirse bounded Codex fix
→ Claude CODE DONE / knowledge
```

## Claude limitine geldim, Codex devam etsin

```text
Codex'i normal aç
→ implementation_worker verme
→ full_lifecycle resume promptu ver
→ repository state'ten aynı run'a devam etsin
```

Bu son durum delegated implementation değildir.

---

# 20. Kısa copy/paste prompt kataloğu

## A. Claude-only

```text
Work on <TASK> in full_lifecycle mode.

Follow AGENTS.md, CLAUDE.md, and the deterministic workflow.
Create or resume the deterministic run and complete the required lifecycle autonomously.
Do not redo completed states.
Use progressive disclosure.
Do not ask for routine workflow approvals.
Do not perform unrelated improvements.
Stop when the required final state is reached.
```

### Türkçe karşılığı

```text
<TASK> üzerinde full_lifecycle modunda çalış.

AGENTS.md, CLAUDE.md ve deterministic workflow'u takip et.
Deterministic run'ı oluştur veya devam et; gerekli lifecycle'ı otonom tamamla.
Tamamlanmış state'leri tekrar yapma, progressive disclosure kullan, rutin onay isteme ve ilgisiz iyileştirme yapma.
Gerekli final state'e ulaştığında dur.
```

## B. Codex-only

```text
Work on <TASK> in full_lifecycle mode.

Follow AGENTS.md and the deterministic workflow.
Create or resume the run and continue autonomously through the required lifecycle.
Do not redo completed states.
Do not rely on previous chat history.
Do not perform unrelated improvements.
Stop at the required final state.
```

### Türkçe karşılığı

```text
<TASK> üzerinde full_lifecycle modunda çalış.

AGENTS.md ve deterministic workflow'u takip et.
Run'ı oluştur veya devam et; gerekli lifecycle boyunca otonom ilerle.
Tamamlanmış state'leri tekrar yapma, önceki chat geçmişine dayanma, ilgisiz iyileştirme yapma ve gerekli final state'te dur.
```

## C. Claude orchestrator + Codex

```text
Work on <TASK> as the lifecycle orchestrator.

Own DISCOVER, EVIDENCE, PLAN, freeze, VERIFY, REVIEW, CODE DONE, delivery decisions, and knowledge work yourself.

Delegate ONLY application implementation to Codex using the explicit implementation_worker role.

After Codex returns, continue the same run yourself.
If a bounded implementation correction is required, dispatch Codex again only as implementation_worker with a focused fix instruction.

Do not let the worker plan, refreeze, review, deliver, perform knowledge work, or delegate further.

Continue autonomously until the required final state and stop.
```

### Türkçe karşılığı

```text
<TASK> üzerinde lifecycle orchestrator olarak çalış.

DISCOVER, EVIDENCE, PLAN, freeze, VERIFY, REVIEW, CODE DONE, delivery kararları ve knowledge işinin sahibi sen ol.
Yalnız application implementation'ını explicit implementation_worker rolüyle Codex'e delege et.
Codex döndükten sonra aynı run'a sen devam et; bounded fix gerekirse focused instruction ile yalnız worker olarak tekrar çağır.
Worker'ın planning, refreeze, review, delivery, knowledge veya delegation yapmasına izin verme.
Gerekli final state'e kadar otonom ilerle ve dur.
```

## D. Codex worker

```text
Act as implementation_worker for the currently active deterministic task.

Consume the frozen TASK, EVIDENCE, and PLAN.
Implement only the authorized application scope.
Do not plan, refreeze, review, deliver, modify knowledge, or delegate.

If material scope/planning change is required, return a blocker.

Report changed paths and focused checks, return control to the orchestrator, and stop.
```

### Türkçe karşılığı

```text
Mevcut aktif deterministic task için implementation_worker olarak davran.
Frozen TASK, EVIDENCE ve PLAN'ı kullan; yalnız yetkili application scope'u uygula.
Planning, refreeze, review, delivery, knowledge veya delegation yapma.
Material scope/planning değişikliği gerekirse blocker döndür.
Changed path'leri ve focused check'leri raporla, control'ü orchestrator'a döndür ve dur.
```

## E. Cross-agent resume

```text
Resume the currently active deterministic task in full_lifecycle mode.

Resolve the active run from repository state, determine the last valid workflow state, and continue from there.

Do not redo completed states.
Do not rely on previous chat history.
Continue autonomously until the required final state or a genuine user decision is required.
```

### Türkçe karşılığı

```text
Mevcut aktif deterministic task'a full_lifecycle modunda devam et.
Active run'ı repository state'ten çöz, son geçerli workflow state'ini belirle ve buradan devam et.
Tamamlanmış state'leri tekrar yapma, önceki chat geçmişine dayanma.
Gerekli final state'e veya gerçek user kararı gerektiren noktaya kadar otonom ilerle.
```

## F. Bounded fix

```text
Act as implementation_worker for the currently active task.

Fix ONLY this verification/review finding:

<FINDING>

Stay inside the frozen TASK/EVIDENCE/PLAN and authorized scope.
Do not plan, refreeze, review, mark CODE DONE, deliver, modify knowledge, or delegate.

Run focused implementation checks, report the correction and changed paths, return control to the orchestrator, and stop.
```

### Türkçe karşılığı

```text
Mevcut aktif task için implementation_worker olarak davran.

Yalnız şu verification/review bulgusunu düzelt:

<BULGU>

Frozen TASK/EVIDENCE/PLAN ve yetkili scope içinde kal. Planning, refreeze, review, CODE DONE, delivery, knowledge veya delegation yapma.
Focused implementation check'leri çalıştır; düzeltmeyi ve changed path'leri raporla, control'ü orchestrator'a döndür ve dur.
```

---

# 21. Ana prensipler

1. **1 task = 1 deterministic run.**
2. Tercihen **1 task = 1 ana session.**
3. Session persistent state değildir.
4. Chat geçmişi source of truth değildir.
5. Agent identity ile execution role aynı şey değildir.
6. Claude normal invocation'da `full_lifecycle` çalışabilir.
7. Codex normal invocation'da `full_lifecycle` çalışabilir.
8. `implementation_worker` yalnız explicit bounded invocation'dır.
9. Claude orchestrator olduğunda lifecycle ownership Claude'da kalır.
10. Codex worker yalnız frozen implementation contract'ını uygular.
11. Worker kendi scope'unu genişletmez.
12. Worker review/CODE DONE/delivery/knowledge yapmaz.
13. Worker recursive delegation yapmaz.
14. Resume ile delegation farklı kavramlardır.
15. Claude → Codex normal resume durumunda Codex `full_lifecycle` olabilir.
16. Claude → Codex delegated implementation durumunda Codex `implementation_worker` olur.
17. Bounded fix loop orchestrator tarafından kontrol edilir.
18. Reviewer/verifier bounded context ile çalışır.
19. CODE DONE ile KNOWLEDGE DONE ayrıdır.
20. Linear/Markdown task-management katmanıdır; deterministic run execution katmanıdır.
21. Progressive disclosure kullanılır.
22. Küçük task küçük context, küçük plan, küçük diff ve odaklı verification üretmelidir.
23. Agent final state'e ulaştığında durur.
24. Yeni task tercihen temiz bir ana session'da başlar.

---

# 22. En pratik kullanım özeti

Senin Claude + Codex kullanımında günlük akış:

```text
1. Claude Code'u aç.

2. Claude'a:
   "Work on Linear issue TODO-123 as the lifecycle orchestrator..."
   promptunu ver.

3. Claude:
   DISCOVER
   EVIDENCE
   PLAN
   FREEZE

4. Claude Codex'i:
   AGENT_ROLE=implementation_worker
   sınırıyla çağırır.

5. Codex:
   IMPLEMENT
   focused checks
   return

6. Claude:
   VERIFY
   REVIEW

7. Problem varsa:
   Claude → bounded fix → Codex worker → return

8. Claude:
   CODE DONE
   required knowledge transaction
   KNOWLEDGE DONE
   final report
   STOP
```

Kullanıcının tek tek:

```text
plan yap
codex'i çağır
verify et
review yap
wiki'yi güncelle
```

demesi hedef değildir.

Doğru orchestrator promptu verildiğinde Claude bütün akışı kendi yönetmelidir.

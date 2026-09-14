# Agent Session ve Prompt Rehberi

Bu rehber, deterministic agent workflow kullanırken Claude Code veya
Codex ile bir task'ın bir session içinde nasıl yürütüleceğini anlatır.
Linear kullanan ve kullanmayan projeler için aynı temel model
geçerlidir.

## 1. Temel model

Ana kural:

> **1 task = 1 deterministic run.**

Tercih edilen kullanım:

> **1 task = 1 ana Claude/Codex session.**

Ancak session workflow state'i değildir. Bir session kapanabilir, başka
bir session açılabilir, hatta uygun durumda Claude'dan Codex'e
geçilebilir. Kalıcı state chat geçmişinde değil şuralardadır:

-   Git ve mevcut repository state'i
-   `.agents/runs/<TASK-ID>/`
-   `TASK.md`
-   `EVIDENCE.md`
-   `PLAN.md`
-   `RUN.yaml`
-   gerektiğinde `RESULT.md`
-   canonical proje dokümantasyonu
-   gerektiğinde LLM Wiki

Bu nedenle Plan, Implement, Verify ve Review için kullanıcının ayrı ayrı
manuel session açması gerekmez.

``` text
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

Normal happy-path'te agent bu state'ler arasında kullanıcıdan rutin onay
istemeden ilerlemelidir.

------------------------------------------------------------------------

## 2. Plan için ayrı Claude session gerekir mi?

Hayır.

`DISCOVER → EVIDENCE → PLAN → IMPLEMENT` aynı ana session içinde
yürüyebilir.

Claude Code'un **Plan Mode** özelliği ile deterministic workflow
içindeki `PLAN.md` aynı şey değildir.

Claude Plan Mode, agent'ın o anda nasıl çalışacağını belirleyen bir
çalışma modudur. Buna karşılık:

``` text
.agents/runs/TODO-123/PLAN.md
```

task'ın frozen ve denetlenebilir implementation contract'ıdır.

Örnek:

``` text
Claude Plan Mode
      ↓
DISCOVER
      ↓
EVIDENCE
      ↓
PLAN.md
      ↓
freeze
      ↓
Plan Mode'dan çık
      ↓
IMPLEMENT
      ↓
VERIFY
```

Bunun için yeni session açılmaz.

------------------------------------------------------------------------

## 3. Reviewer ve verifier ayrı session mı?

Kullanıcının manuel olarak ayrı Claude terminal/session açması gerekmez.

Reviewer ve verifier gerektiğinde bounded subagent/context olarak
çalışabilir.

``` text
                    ┌─ code reviewer
Main task session ──┤
                    └─ verifier
```

Reviewer'a tüm session geçmişini vermek yerine yalnız gerekli context
verilmelidir:

-   TASK ve acceptance criteria
-   frozen PLAN
-   ilgili evidence referansları
-   task diff'i
-   ilgili test sonuçları

Verifier'ın context'i mümkünse daha da küçük tutulmalıdır.

Reviewer/verifier, repository'nin gerçek verification komutlarının
yerine geçmez.

------------------------------------------------------------------------

## 4. Agent ne zaman kullanıcıya soru sormalı?

Workflow state geçişleri soru sebebi değildir.

### Sormaması gereken örnek

> PLAN tamamlandı. Implementation'a geçeyim mi?

Workflow IMPLEMENT'a izin veriyorsa agent devam etmelidir.

### Sorması gereken örnek

> Acceptance criteria status code belirtmiyor. Mevcut API'lerde iki
> farklı contract kullanılıyor ve authoritative kaynaklardan hangisinin
> geçerli olduğu çözülemiyor. Hangisini uygulayalım?

Agent yalnızca aşağıdaki gibi durumlarda durmalıdır:

-   önemli requirement belirsizliği,
-   authoritative evidence kaynakları arasında çözülemeyen çatışma,
-   geri döndürülemez/destructive ve onay gerektiren işlem,
-   task ve repository'den çözülemeyen önemli scope genişlemesi.

------------------------------------------------------------------------

# 5. Linear kullanan proje

Linear task-management katmanıdır:

``` text
Linear
  = Ne yapacağız?

.agents/runs/
  = Agent bunu hangi frozen contract altında yaptı?

docs/wiki/
  = Proje ne biliyor ve neden böyle karar verdi?
```

Örneğin Linear issue:

``` text
TODO-123 — Add todo completion endpoint

PATCH /api/v1/todos/{id}/complete

Acceptance Criteria:
- Existing todo can be completed.
- Missing todo returns 404.
- Completing an already completed todo is idempotent.
- Tests are included.
```

Bu issue için deterministic run:

``` text
.agents/runs/TODO-123/
├── TASK.md
├── EVIDENCE.md
├── PLAN.md
├── RUN.yaml
├── RESULT.md
└── review/
```

## Linear --- ideal günlük prompt

### English

``` text
Work on Linear issue TODO-123.

Follow this repository's AGENTS.md, CLAUDE.md, and deterministic workflow.

Use TODO-123 as the task identity and execute the complete task lifecycle autonomously.

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

### Türkçe

``` text
Linear'daki TODO-123 issue'su üzerinde çalış.

Bu repository'nin AGENTS.md, CLAUDE.md ve deterministic workflow kurallarını takip et.

TODO-123'ü task identity olarak kullan ve task'ın tüm lifecycle'ını otonom olarak yürüt.

İlgili deterministic run'ı oluştur veya mevcutsa devam ettir; gerektiğinde baseline al ve DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE ve gerekli knowledge transaction aşamalarından KNOWLEDGE DONE'a kadar ilerle.

Progressive disclosure kullan. İlgisiz repository dosyalarını, wiki sayfalarını, historical run'ları, Linear issue'larını veya session geçmişini yükleme.

Mevcut bir run'a devam ediyorsan tamamlanmış workflow aşamalarını tekrar yapma.

Rutin workflow geçişleri için benden onay isteme. Yalnızca şu durumlarda sor:
- önemli bir requirement belirsizliği,
- authoritative evidence kaynakları arasında çatışma,
- onay gerektiren geri döndürülemez veya destructive işlem,
- task ve repository'den çözülemeyen önemli bir scope genişlemesi.

Fırsat bulmuşken iyileştirme veya ilgisiz refactor yapma.

Task gerekli final state'e ulaştığında, izin veriliyorsa task-management durumunu güncelle, verification kanıtlarını içeren kısa bir final rapor ver ve dur.

Başka bir task'a geçme.
```

Bu prompt normal durumda tek başına yeterli olmalıdır.

------------------------------------------------------------------------

# 6. Linear kullanmayan proje

Linear zorunlu değildir. Markdown tabanlı proje yönetimi kullanılabilir.

Örnek:

``` text
docs/project/
├── ROADMAP.md
├── BACKLOG.md
├── sprints/
│   └── SPRINT-001.md
└── tasks/
    └── TODO-001.md
```

Task kaynağı:

``` text
docs/project/tasks/TODO-001.md
```

Task çalıştırılırken bu kaynak deterministic run'a normalize edilir:

``` text
docs/project/tasks/TODO-001.md
        ↓
.agents/runs/TODO-001/TASK.md
```

`docs/project/` proje yönetimi için, `.agents/runs/` execution contract
için kullanılır.

## Markdown task --- ideal günlük prompt

### English

``` text
Work on project task TODO-001 defined in docs/project/tasks/TODO-001.md.

Follow this repository's AGENTS.md, CLAUDE.md, and deterministic workflow.

Use TODO-001 as the deterministic task identity.

Create or resume the corresponding run and execute the complete lifecycle autonomously through DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE, and the required knowledge transaction until KNOWLEDGE DONE.

Treat the project task as the task-management source, but normalize the executable contract into the deterministic run according to repository policy.

Use progressive disclosure and do not load unrelated backlog items, sprint documents, wiki pages, historical runs, or repository files.

Do not ask for approval between routine workflow states.

Stop only for a material ambiguity, authoritative evidence conflict, approval-required irreversible action, or material scope expansion that cannot be resolved from repository evidence.

When complete, update the Markdown task/sprint status if repository policy permits it, report the verification evidence and final state, and stop.

Do not start another backlog item.
```

### Türkçe

``` text
docs/project/tasks/TODO-001.md içinde tanımlanan TODO-001 proje task'ı üzerinde çalış.

Bu repository'nin AGENTS.md, CLAUDE.md ve deterministic workflow kurallarını takip et.

TODO-001'i deterministic task identity olarak kullan.

İlgili run'ı oluştur veya mevcutsa devam ettir ve DISCOVER, EVIDENCE, PLAN, freeze, IMPLEMENT, VERIFY, REVIEW, CODE DONE ve gerekli knowledge transaction aşamalarından KNOWLEDGE DONE'a kadar tüm lifecycle'ı otonom olarak yürüt.

Project task dosyasını task-management kaynağı olarak kabul et, ancak çalıştırılabilir contract'ı repository policy'sine göre deterministic run içine normalize et.

Progressive disclosure kullan; ilgisiz backlog item'larını, sprint dokümanlarını, wiki sayfalarını, historical run'ları veya repository dosyalarını yükleme.

Rutin workflow state'leri arasında benden onay isteme.

Yalnızca önemli bir belirsizlik, authoritative evidence çatışması, onay gerektiren geri döndürülemez işlem veya repository evidence ile çözülemeyen önemli bir scope genişlemesi varsa dur.

Tamamlandığında repository policy izin veriyorsa Markdown task/sprint durumunu güncelle, verification kanıtlarını ve final state'i raporla ve dur.

Başka bir backlog item'ına başlama.
```

------------------------------------------------------------------------

# 7. Session yarıda kapanırsa

Session'ın kapanması run'ın kaybolduğu anlamına gelmez.

Örneğin:

``` text
TODO-123
├─ BASELINE ✓
├─ DISCOVER ✓
├─ EVIDENCE ✓
├─ PLAN ✓
├─ FREEZE ✓
└─ IMPLEMENT %40
```

Yeni Claude/Codex session'ı mevcut state'i repository'den
çözebilmelidir.

## Resume prompt

### English

``` text
Resume the currently active deterministic task.

Follow AGENTS.md, CLAUDE.md, and the repository workflow.

Resolve the active run from repository state, inspect its frozen task/evidence/plan and current Git state, determine the last valid workflow state, and continue from there.

Do not recreate or redo completed workflow states.

Do not rely on previous chat history.

Continue autonomously until the task reaches its required completion state or a genuine user decision is required.
```

### Türkçe

``` text
Şu anda aktif olan deterministic task'a devam et.

AGENTS.md, CLAUDE.md ve repository workflow'unu takip et.

Aktif run'ı repository state'inden bul; frozen task/evidence/plan ile mevcut Git state'ini incele, son geçerli workflow state'ini belirle ve oradan devam et.

Tamamlanmış workflow aşamalarını yeniden oluşturma veya tekrar yapma.

Önceki chat geçmişine güvenme.

Task gerekli completion state'e ulaşana veya gerçekten kullanıcı kararı gerekene kadar otonom olarak devam et.
```

Bu özellik önemlidir:

> **Chat history convenience'tır; source of truth değildir.**

------------------------------------------------------------------------

# 8. CODE DONE ve KNOWLEDGE DONE

Kodun tamamlanması ile proje bilgisinin güncellenmesi iki ayrı
transaction olarak düşünülür.

``` text
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

Deterministic implementation sırasında wiki read-only'dir. Task kendi
execution'ı sırasında geçmiş bilgisini değiştirmemelidir.

> **Task kendi geçmişini değiştiremez. Ama bittikten sonra gelecek
> task'lar için geçmiş olur.**

Eğer repository workflow'un final completion state'i `KNOWLEDGE DONE`
ise agent'ın CODE DONE'da:

> Wiki'yi de güncelleyeyim mi?

diye sormaması gerekir. Workflow zaten devam etmesini söylüyorsa devam
etmelidir.

------------------------------------------------------------------------

# 9. Recovery prompt --- agent gereksiz yere CODE DONE'da durursa

Bu normal happy-path değildir. Agent workflow'u erken durdurduysa
kullanılabilir.

### English

``` text
Continue the current task from its CODE DONE state.

Complete the required knowledge transaction according to the repository policy.

Use the existing LLM Wiki workflow, keep the update proportional to the actual task, run the required wiki lint process, resolve relevant findings without inventing facts, and continue until KNOWLEDGE DONE.

Do not modify application code unless a genuine inconsistency requires my decision.

Report the final state and stop.
```

### Türkçe

``` text
Mevcut task'a CODE DONE durumundan devam et.

Repository policy'sine göre gerekli knowledge transaction'ı tamamla.

Mevcut LLM Wiki workflow'unu kullan, güncellemeyi gerçekten yapılan task ile orantılı tut, gerekli wiki lint sürecini çalıştır, ilgili bulguları bilgi uydurmadan çöz ve KNOWLEDGE DONE'a kadar devam et.

Gerçek bir tutarsızlık benim kararımı gerektirmediği sürece application code'u değiştirme.

Final state'i raporla ve dur.
```

------------------------------------------------------------------------

# 10. Final completion kontrolü

Normal workflow bunu zaten sağlamalıdır. Şüpheli bir durumda read-only
final kontrol istenebilir.

### English

``` text
Perform a final read-only completion check for the current task.

Confirm that the deterministic run reached its required final state, required verification and review gates passed, there are no unexplained or unauthorized changes, and no task requirement remains incomplete.

Do not make new improvements, perform unrelated refactoring, or start another task.

If everything is complete, give me a concise final summary and stop.
```

### Türkçe

``` text
Mevcut task için son bir read-only completion kontrolü yap.

Deterministic run'ın gerekli final state'e ulaştığını, gerekli verification ve review gate'lerinin geçtiğini, açıklanamayan veya yetkisiz değişiklik bulunmadığını ve task requirement'larından hiçbirinin eksik kalmadığını doğrula.

Yeni iyileştirme yapma, ilgisiz refactor yapma veya başka bir task'a başlama.

Her şey tamamlandıysa kısa bir final özet ver ve dur.
```

------------------------------------------------------------------------

# 11. Örnek gerçek session akışı

İdeal durumda kullanıcı-agent konuşması uzun olmamalıdır.

``` text
USER
│
│ Work on Linear issue TODO-123...
│
▼
AGENT
│
├─ issue'yu çözer
├─ run oluşturur/resume eder
├─ baseline alır
├─ discover yapar
├─ evidence oluşturur
├─ plan oluşturur
├─ freeze eder
├─ implement eder
├─ verify eder
├─ review/verifier gate'lerini tamamlar
├─ CODE DONE
├─ knowledge transaction
├─ KNOWLEDGE DONE
├─ task-management durumunu günceller
│
▼
Final report
│
▼
STOP
```

Kullanıcının şunları sırayla yazması hedef değildir:

``` text
Plan yap.
Devam et.
Implement et.
Test et.
Review et.
Wiki'yi güncelle.
Devam et.
```

Bunlar repository workflow'unun sorumluluğudur.

------------------------------------------------------------------------

# 12. Task bittikten sonra aynı session'da yeni task?

Tercih edilen kullanım: **hayır**.

``` text
Session #1
└─ TODO-123
   └─ DONE

Session #2
└─ TODO-124
   └─ DONE
```

Bunun nedeni determinism zorunluluğundan çok context hijyenidir.

Yeni task'ın önceki task'ın uzun conversation history'sine ihtiyacı
olmamalıdır. Gerekli bilgi:

``` text
Git
+ repository
+ canonical docs
+ task
+ gerektiğinde wiki
```

üzerinden yeniden bulunmalıdır.

Bu nedenle:

> **1 task = 1 session bir kullanım tercihi; 1 task = 1 run sistem
> kuralıdır.**

Çok küçük ve birbirine sıkı bağlı işler için aynı session teknik olarak
mümkün olsa da her task yine ayrı run olmalı ve önceki task tamamen
tamamlanmadan sonraki task başlatılmamalıdır.

------------------------------------------------------------------------

# 13. Token ve context açısından davranış

Deterministic workflow tüm control plane'i her task'ta modele yüklemek
anlamına gelmez.

Progressive disclosure uygulanmalıdır.

Başlangıçta:

``` text
TASK
+ ilgili repository code
+ ilgili tests
```

yeterliyse wiki açılmaz.

Gerektiğinde:

``` text
index
 ↓
ilgili decision
 ↓
ilgili lesson
 ↓
gerekirse source
```

şeklinde ilerlenir.

Yüklenmemesi gerekenler:

-   tüm `.agents/**`
-   tüm `docs/wiki/**`
-   eski run'ların tamamı
-   bütün Linear backlog'u
-   bütün sprint geçmişi
-   gereksiz conversation history
-   task ile ilgisiz capability/skill dokümanları

Prensip:

> **Determinism must not require loading the entire control plane or
> knowledge base into model context.**

------------------------------------------------------------------------

# 14. Kısa kullanım özeti

## Linear

``` text
Yeni session aç
→ Linear issue ID ver
→ agent lifecycle'ı otonom tamamlasın
→ final report
→ session kapat
```

## Markdown task

``` text
Yeni session aç
→ task dosyasını/ID'sini ver
→ agent lifecycle'ı otonom tamamlasın
→ task/sprint state güncellensin
→ final report
→ session kapat
```

## Session yarıda kesildi

``` text
Yeni session
→ active run'ı repository'den çöz
→ frozen state'i oku
→ kaldığı yerden devam et
```

## Agent rutin onay istedi

Workflow cevabı zaten belirliyorsa onay verme döngüsü oluşturmak yerine
agent'a mevcut state'ten otonom devam etmesini söyle.

------------------------------------------------------------------------

# 15. Ana prensipler

1.  **1 task = 1 deterministic run.**
2.  Tercihen **1 task = 1 ana session.**
3.  Plan ve implementation için manuel ayrı session gerekmez.
4.  Session state değildir.
5.  Chat geçmişi source of truth değildir.
6.  Rutin state geçişlerinde kullanıcı onayı gerekmez.
7.  Reviewer/verifier bounded context ile çalışır.
8.  CODE DONE ile KNOWLEDGE DONE ayrıdır.
9.  Agent final state'e ulaştığında durur.
10. Yeni task tercihen temiz bir session'da başlar.
11. Linear/Markdown task-management katmanıdır; deterministic run
    execution katmanıdır.
12. Küçük task küçük context, küçük plan, küçük diff ve odaklı
    verification üretmelidir.

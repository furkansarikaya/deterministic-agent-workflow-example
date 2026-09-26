# Agent Session ve Prompt Rehberi

Bu, deterministic agent workflow'un günlük kullanım rehberidir. Kuralların kendisi `AGENTS.md` ve `.agents/WORKFLOW.md` içindedir; burada **nasıl başlatıp bitirdiğin** ve **prompt'ları nasıl kısa tutacağın** anlatılır. Bir kural bu rehberle çelişirse `.agents/WORKFLOW.md` ve `.agents/ENFORCEMENT.md` kazanır.

---

## 1. Temel fikir

> **Workflow repository'nin; sen yalnızca niyetini söylersin.**

Lifecycle'ı, delegation'ı, doğrulamayı, cleanup'ı ve durma koşullarını repository tanımlar (`AGENTS.md` boot protocol'ü, `.agents/`, `scripts/agent.sh`). Bu yüzden prompt'a bu mekaniği yazmazsın: agent zaten `AGENTS.md`'yi okur ve uygular. Claude Code ve Codex aynı repository sözleşmesini kullanır.

Repository'nin sahip olduğu durum (chat geçmişinde **değil**):

| Ne | Nerede | Kalıcı mı |
|---|---|---|
| Kurallar, roller, pipeline tablosu | `AGENTS.md`, `CLAUDE.md`, `.agents/` (`WORKFLOW.md`, `ENFORCEMENT.md`, `config.yaml`, `modes/`, `templates/`) | Evet |
| Task tanımı | task kaynağı (ör. `docs/project/tasks/TASK-123.md`) | Evet |
| Proje bilgisi | `docs/wiki/` (yalnız kalıcı sözleşme/karar değiştiyse güncellenir) | Evet |
| Kod ve testler | Git | Evet |
| Çalışan task'ın durumu | `.agents/runs/<TASK-ID>/` | **Hayır — geçici** |

`.agents/runs/` gitignore'dadır ve commit edilmez. Task bitince agent run dizinini siler; kalıcı kayıt, task kaynağına yayınlanan **completion report** ve Git geçmişidir.

---

## 2. Tek cümlelik prompt kuralı

Normal kullanımda prompt tek cümledir: **ne istediğini** söyle, task kaynağı varsa **hangisi olduğunu** söyle. Gerisini agent yapar:

1. `AGENTS.md`'yi ve `.agents/WORKFLOW.md`'yi okur, `agent.sh status` ile aktif task'a bakar.
2. Run'ı oluşturur veya devam eder, task'ı sınıflandırır (`classify`), task branch'ini açar (`branch`), baseline alır (`baseline`).
3. Sınıfın gerektirdiği artifact'ları üretir ve dondurur, gerekirse bounded sub-agent'lar kullanır.
4. Tek implementation worker ile implemente eder; bağımsız REVIEW / QA / VERIFY gate'lerini geçirir.
5. Completion report'u yayınlar, `delivery-check` yapar, run'ı temizler (`cleanup`) ve **durur**.

Prompt'a **yazma**: "DISCOVER yap, EVIDENCE yaz, freeze et…" gibi lifecycle adımları, "Codex'e delege et" gibi topology talimatları, "approval isteme" gibi durma kuralları, "bitince başka task'a geçme" gibi stop koşulları. Bunlar repository'de tanımlıdır; prompt'ta tekrarlamak kuralı değiştirmez, sadece çelişki riski yaratır.

Prompt'a **yaz**: niyet (ne, nerede, hangi davranış), varsa task kimliği veya dosyası, kontrolün sana döneceği sınır (ör. "…then stop before delivery"), varsa senin bildiğin ve repository'den çıkarılamayacak kısıt. Kural: **Prompt = intent + user-control boundary. The repository owns execution.**

### Agent ne zaman sorar / durur?

Rutin geçişlerde onay istemez. Yalnızca: task'tan ve repository'den çözülemeyen belirsizlik, yetkili kaynaklar arasında çatışma, geri döndürülemez/destructive işlem, çözülemeyen scope genişlemesi. Ayrıca commit/push/PR/task-system yazımı için **senin açık yetkin** gerekir (`CODE_DONE` bunu vermez).

---

## 3. Bir task baştan sona nasıl akar?

```text
task → classify → branch → baseline → DISCOVER → evidence → [architect] → plan → [QA plan]
     → freeze → freshness → IMPLEMENT → IMPLEMENTED
     → { REVIEW | QA | VERIFY gate'leri } → CODE_DONE (quality gate)
     → [knowledge] → completion report → DONE → delivery-check → cleanup → STOP
```

### Sınıflandırma pipeline'ı belirler

Agent task'ı `.agents/WORKFLOW.md`'deki kriterlere göre sınıflandırır (en yüksek eşleşen sınıf kazanır); sınıf hangi artifact'ların üretileceğini ve hangi gate'lerin zorunlu olduğunu belirler. `./scripts/agent.sh pipeline <TASK-ID>` bunu gösterir.

| Sınıf | Örnek | Evidence | Architect | QA plan + QA gate | REVIEW gate | VERIFY gate |
|---|---|---|---|---|---|---|
| TRIVIAL | typo, yorum, tek satırlık config | – | – | – | – | ✓ |
| STANDARD | sınırlı feature/bug fix | ✓ | – | ✓ | opsiyonel | ✓ |
| COMPLEX | çok modül, yeni entegrasyon, persistence/API değişikliği | ✓ | ✓ | ✓ | ✓ | ✓ |
| CRITICAL | auth, kripto, destructive migration, güvenlik sınırı | ✓ | ✓ | ✓ | ✓ | ✓ |

### Çalışma dosyaları

`.agents/runs/<TASK-ID>/` altında yalnızca sınıfın gerektirdiği dosyalar bulunur: `RUN.yaml`, `TASK.md`, `PLAN.md` her zaman; `EVIDENCE.md` (TRIVIAL değil), `QA_PLAN.md` ve `QA_REPORT.md` (STANDARD ve üstü), `REVIEW.md` (review gerekliyse), `VERIFY.md`, sonunda `COMPLETION_REPORT.md`. Sahiplik ve donma kuralları `.agents/WORKFLOW.md`'de; notlar, scratch veya özet dosyası **oluşturulmaz**.

---

## 4. Roller, sub-agent'lar ve implementation ownership

Rol, agent kimliği değildir: aynı Claude Code veya Codex, çağrıldığı role göre davranır. Normal başlatılan her session `full_lifecycle`'dır (Orchestrator).

| Rol | Ne yapar | Ne yapmaz |
|---|---|---|
| **Orchestrator** (`full_lifecycle`) | Lifecycle'ın sahibi: sınıflandırır, evidence'ı birleştirir, plan yazar, dondurur, hata teşhisi ve bounded fix kararı verir, quality gate'i değerlendirir, raporu yazar, cleanup yapar. **DONE'ı yalnız o ilan eder.** | Kontrolsüz delegation zinciri kurmaz |
| **Explorer** | Tek bir görev tanımı (amaç, sınır, çıktı, durma koşulu) için kısa, kaynak referanslı bulgular döndürür | Kod yazmaz, scope genişletmez |
| **Architect** | Yalnız COMPLEX/CRITICAL: planın `## Architecture` bölümünü tasarlar | Implemente etmez |
| **QA** | Implementation'dan **önce** `QA_PLAN.md`; sonra dondurulmuş plana göre `QA_REPORT.md` ve QA gate | Production kodunu değiştirmez, kriterleri gevşetmez |
| **Implementer** | Dondurulmuş plan/scope/QA planı içinde en küçük doğru değişiklik | Scope, QA kriteri veya evidence'ı değiştirmez |
| **Reviewer** | Gerçek diff'i inceler (`REVIEW.md`), REVIEW gate | Kodu düzeltmez |
| **Verifier** | Planın uygulandığını build/test/lint ile kanıtlar (`VERIFY.md`), VERIFY gate | Geçmek için implementation'ı değiştirmez |

- **Sub-agent'lar sınırlıdır.** Her biri açık bir görev tanımıyla çalışır, başka agent oluşturamaz. Swarm yoktur, recursive delegation yoktur. Paralel exploration yalnız bağımsız hedefler için ve sınıfın izin verdiği sayıda (`max_explorers`).
- **Implementation tek worker'dır.** Aynı kodu aynı anda birden fazla agent değiştirmez.
- **Topology** (`.agents/config.yaml`'de `default_topology`, run'da `execution.topology`): `standalone`'da Orchestrator RED/GREEN'i kendisi yazar; `orchestrated`'da uygulama kodunu yalnız `implementation_worker` yazar (`scripts/worker-run.sh` ile), Orchestrator yazamaz ve worker başarısız olursa da kendisi yazmaz. Hangi ürün hangi rolü oynar repository config'ine bağlıdır; sen prompt'ta belirtmezsin.
- **Bağımsız gate'ler.** `deterministic` modda REVIEW, QA ve VERIFY geçişleri sırasıyla `independent_reviewer`, `independent_qa`, `independent_verifier` rolünden gelmelidir; implementation kendi işini onaylayamaz.

Gate'ler tam final ağaca ve rolün kendi raporuna bağlıdır: kodda veya rapor dosyasında sonradan tek bayt değişirse ilgili gate'ler geçersiz olur ve yeniden koşar.

### Başarısızlık ve bounded remediation

Bir gate başarısız olursa kontrol Orchestrator'a döner; teşhis eder (implementation hatası → bounded fix; plan/evidence/scope hatası → amendment + refreeze; ortam sorunu → BLOCKED) ve yalnız gereken minimum düzeltmeyi yaptırır. En fazla **2 fix**; bütçe biterse ya amendment ile yeni bütçe açılır ya da run `terminate FAILED|BLOCKED` ile biter. Sonsuz döngü yoktur.

---

## 5. Run'lar geçicidir: cleanup, resume, follow-up

- **Bitiş:** `CODE_DONE` → (gerekirse knowledge) → completion report yayını → `DONE` → `delivery-check` → `agent.sh cleanup <TASK-ID>`. Cleanup run dizinini siler ve `ACTIVE_RUN`'ı boşaltır. Agent ancak bundan sonra "bitti" der ve durur.
- **Knowledge transaction opsiyoneldir:** yalnız task kalıcı bir proje sözleşmesini veya belgelenmiş mimariyi değiştirdiyse `docs/wiki/` güncellenir; aksi halde `not_applicable`. Run artifact'ları wiki'ye toplu aktarılmaz.
- **Yarıda kalırsa:** kalıcı state chat'te değil diskte (run dizini + Git). Yeni bir Claude/Codex session'ı aynı task ID ile devam eder; `freshness` ve `verify-handoff` geçtikten sonra donmuş işe güvenir ve tamamlanmış aşamaları tekrarlamaz. Session'lar arası geçiş (Claude → Codex veya tersi) delegation değil, normal `full_lifecycle` resume'dur.
- **Bitmiş task'ı yeniden açmak:** cleanup'tan **önce** ve teslim commit'inden önce `agent.sh amend` ile (yetkili, gerekçeli) mümkündür. Cleanup'tan sonra iş **yeni bir task**tır.
- **Commit/push/PR:** `delivery-check` yalnız yerel hazırlığı kanıtlar. Teslimi sen açıkça yetkilendirirsin.

---

## 6. Prompt kataloğu

> **Prompt = intent + user-control boundary. The repository owns execution.**
> Sen NE istediğini ve kontrolün NEREDE sana döneceğini söylersin; lifecycle'ı (branch, keşif, dondurma, delegation, QA/review/verification, knowledge, cleanup) repository yürütür ve prompt'a yazılmaz.

Hepsi kısa ve niyet odaklıdır; İngilizce ve Türkçe karşılıkları aynı işi yapar. Örnekteki task kimliklerini ve konuları kendinle değiştir.

Kullanabileceğin sınırlar (yalnız workflow'un gerçekten tanımladığı yerler):

| Sınır | Anlamı |
|---|---|
| `through task completion, then stop before delivery` | Task, workflow'un tamamlanma noktasına kadar yürür (gate'ler geçer, completion report yayınlanır, `DONE` ve `cleanup`); commit/push/PR yapılmaz. Implementation işlerinin normal sınırı budur. |
| `stop before merge` | Delivery workflow'u (yerel `delivery-check`, sonra senin yetkinle commit/push/PR) yürür; merge her zaman sende kalır (workflow hiçbir zaman merge etmez). Delivery işlerinin normal sınırı budur. |
| `Do not start implementation` | Yalnız planlama/reconcile; kod değişmez. |
| `do not change anything` | Yalnız okuma/analiz; run gerekmez. |

Sınır belirtmezsen implementation işleri yine `CODE_DONE`/`DONE` sonrası durur ve teslim için senin açık yetkini bekler; sınırı yazmak niyeti netleştirir.

### Small change / minor adjustment

```text
Fix the typo in the README quick-start heading through task completion, then stop before delivery.
```
```text
README hızlı başlangıç başlığındaki yazım hatasını task completion'a kadar düzelt ve delivery'den önce dur.
```

### Bug fix

```text
Fix the pagination bug through task completion, then stop before delivery.
```
```text
Pagination bug'ını task completion'a kadar düzelt ve delivery'den önce dur.
```

Bug bir task kaynağında tanımlıysa:

```text
Fix BUG-42 through task completion, then stop before delivery.
```
```text
BUG-42'yi task completion'a kadar düzelt ve delivery'den önce dur.
```

### New feature or behavior change

```text
Implement the requested cache invalidation change through task completion, then stop before delivery.
```
```text
İstenen cache invalidation değişikliğini task completion'a kadar tamamla ve delivery'den önce dur.
```

```text
Add a DELETE /api/v1/todos/{id} endpoint (204 on success, 404 for an unknown id) through task completion, then stop before delivery.
```
```text
DELETE /api/v1/todos/{id} endpoint'ini (başarıda 204, bilinmeyen id için 404) task completion'a kadar ekle ve delivery'den önce dur.
```

Bilinen ve repository'den çıkarılamayacak bir kısıt varsa cümleye ekle:

```text
Add tag filtering to GET /api/v1/todos without adding a new dependency, through task completion, then stop before delivery.
```
```text
GET /api/v1/todos'a tag filtresi ekle, yeni bağımlılık ekleme; task completion'a kadar tamamla ve delivery'den önce dur.
```

### Normal task execution (task kaynağından)

Task bir Markdown dosyasında tanımlıysa:

```text
Complete docs/project/tasks/TASK-123.md through task completion, then stop before delivery.
```
```text
docs/project/tasks/TASK-123.md'yi task completion'a kadar tamamla ve delivery'den önce dur.
```

Sadece kimlikle:

```text
Complete TASK-123 through task completion, then stop before delivery.
```
```text
TASK-123'ü task completion'a kadar tamamla ve delivery'den önce dur.
```

Feature task'ı:

```text
Complete FEATURE-17 through task completion, then stop before delivery.
```
```text
FEATURE-17'yi task completion'a kadar tamamla ve delivery'den önce dur.
```

### Linear issue'sundan çalışmak

```text
Complete Linear issue TASK-123 through task completion, then stop before delivery.
```
```text
Linear'daki TASK-123 issue'sunu task completion'a kadar tamamla ve delivery'den önce dur.
```

Linear için repository'nin bir task-integration adapter'ı olmalıdır (`.agents/task-integrations/`, ortak arayüz `README.md`'de); repository'de yalnız `markdown` adapter'ı gelir. Adapter yoksa agent completion report'u yayınlayamaz ve durur.

### Documentation-only change

```text
Update the affected documentation and stop before delivery.
```
```text
İlgili dokümantasyonu güncelle ve delivery'den önce dur.
```

```text
Update the API guide to describe the new pagination parameters through task completion, then stop before delivery.
```
```text
API guide'ı yeni pagination parametrelerini anlatacak şekilde task completion'a kadar güncelle ve delivery'den önce dur.
```

### Maintenance / control-plane change

Control plane'in (`.agents/`, şablonlar, script'ler) bakımı, kullanıcı isteğiyle yapılan açık bir istisnadır: dosyalar bir run oluşturulmadan doğrudan güncellenir.

```text
Maintain the control plane: update the workflow templates for the new naming convention, then stop before delivery.
```
```text
Control plane bakımı: workflow template'lerini yeni naming convention'a göre güncelle ve delivery'den önce dur.
```

Rutin bağımlılık/temizlik gibi normal bir maintenance task'ı uygulama kodunu etkiliyorsa normal implementation işi gibi verilir:

```text
Remove the unused legacy helper modules through task completion, then stop before delivery.
```
```text
Kullanılmayan legacy helper modülleri task completion'a kadar kaldır ve delivery'den önce dur.
```

### Planning

```text
Plan TASK-123. Do not start implementation.
```
```text
TASK-123'ü planla. Implementation'a başlama.
```

Plan dondurulunca kontrol sana döner; run diskte kalır ve `Continue TASK-123 …` ile kaldığı yerden devam eder.

### Task-contract reconciliation

Task kaynağı ile mevcut kanonik kararlar/repository durumu arasındaki farkı gidermek için:

```text
Reconcile TASK-123 with the current canonical decisions. Do not start implementation.
```
```text
TASK-123'ü mevcut canonical kararlarla reconcile et. Implementation'a başlama.
```

Task sözleşmesi freeze'den sonra değiştiyse `freshness` bloklar; reconcile bunu amendment ve yeniden freeze ile çözer (implementation ayrıca istenir).

### Devam etmek (session yarıda kaldıysa)

```text
Continue TASK-123 through task completion, then stop before delivery.
```
```text
TASK-123'e task completion'a kadar devam et ve delivery'den önce dur.
```

### Delivery

```text
Deliver TASK-123 using the repository-defined delivery workflow, then stop before merge.
```
```text
TASK-123'ü repository-defined delivery workflow'u kullanarak deliver et ve merge'den önce dur.
```

Delivery yerel `delivery-check` ile başlar; commit, push ve PR açık yetkinle yapılır ve merge her zaman sende kalır. Kısa biçim:

```text
Commit and push the completed TASK-123 work, then stop before merge.
```
```text
Tamamlanan TASK-123 işini commit'le ve push'la, merge'den önce dur.
```

### Bitmiş işin devamı (yeni task)

Cleanup'tan sonra iş yeni bir task'tır:

```text
Follow up on TASK-123: reject titles longer than 200 characters, through task completion, then stop before delivery.
```
```text
TASK-123'ün devamı: 200 karakterden uzun başlıkları reddet; task completion'a kadar tamamla ve delivery'den önce dur.
```

### Durum sormak (değişiklik yapmaz)

```text
What is the state of TASK-123? Do not change anything.
```
```text
TASK-123 hangi aşamada? Hiçbir şeyi değiştirme.
```

### Araştırma / soru (run gerektirmez)

```text
Explain how todo persistence is layered; do not change anything.
```
```text
Todo persistence'ın katmanlarını açıkla; hiçbir şeyi değiştirme.
```

### Bırakmak

```text
Stop TASK-123; it is blocked on an unavailable database.
```
```text
TASK-123'ü bırak; erişilemeyen veritabanı yüzünden bloke.
```

---

## 7. Sık hatalar

- Uzun "lifecycle prompt'ları" yazmak; kural repository'dedir, prompt'taki kopya eskiyebilir ve çelişebilir.
- Run dizinini elle düzenlemek veya commit etmek (geçicidir; state'i script'ler yönetir, elle değiştirilen lifecycle alanları tespit edilir).
- Worker'a review/QA/delivery yaptırmak; bunlar bağımsız rollerin ve Orchestrator'ın işidir.
- "Agent bitti dedi" diye güvenmek; kanıt gate kayıtları ve `delivery-check`'tir.
- Bitmiş run'ı cleanup'tan sonra "yeniden açmaya" çalışmak; yeni task aç.

---

## 8. Hızlı komut referansı

```sh
./scripts/agent.sh status                       # aktif task var mı
./scripts/agent.sh pipeline <TASK-ID>           # sınıf, artifact ve gate gereksinimleri
./scripts/agent.sh validate <TASK-ID>           # run yapısal sağlığı
./scripts/agent.sh delivery-check <TASK-ID>     # yerel teslim hazırlığı (uzaktan bir şey yapmaz)
./scripts/agent.sh cleanup <TASK-ID>            # DONE run'ı sil, ACTIVE_RUN'ı boşalt
./scripts/agent.sh terminate <TASK-ID> FAILED|BLOCKED   # sebep ve kanıt stdin'den
```

Tüm komutlar ve zorunluluk sınıfları: `.agents/VERIFICATION.md`, `.agents/ENFORCEMENT.md`.

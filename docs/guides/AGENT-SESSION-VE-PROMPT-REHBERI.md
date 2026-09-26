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
| Task tanımı | task kaynağı (ör. `docs/project/tasks/TODO-001.md`) | Evet |
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

Prompt'a **yaz**: niyet (ne, nerede, hangi davranış), varsa task kimliği veya dosyası, varsa senin bildiğin ve repository'den çıkarılamayacak kısıt.

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

Hepsi tek cümledir; İngilizce ve Türkçe karşılıkları aynı işi yapar. Köşeli parantez içini kendi task'ınla değiştir.

### Yeni değişiklik

```text
Add a DELETE /api/v1/todos/{id} endpoint that returns 204 and 404 for an unknown id.
```
```text
DELETE /api/v1/todos/{id} endpoint'i ekle; başarıda 204, bilinmeyen id için 404 dönsün.
```

### Task dosyasından çalış (Markdown)

```text
Work on docs/project/tasks/TODO-001.md.
```
```text
docs/project/tasks/TODO-001.md task'ı üzerinde çalış.
```

### Linear issue'sundan çalış

```text
Work on Linear issue TODO-123.
```
```text
Linear'daki TODO-123 issue'su üzerinde çalış.
```

Linear için repository'nin bir task-integration adapter'ı olmalıdır (`.agents/task-integrations/`, ortak arayüz `README.md`'de); repository'de yalnız `markdown` adapter'ı gelir. Adapter yoksa agent completion report'u yayınlayamaz ve durur.

### Küçük düzeltme

```text
Fix the typo in the README quick-start heading.
```
```text
README hızlı başlangıç başlığındaki yazım hatasını düzelt.
```

### Bug fix

```text
Fix: completing an already completed todo returns 500 instead of 409.
```
```text
Düzelt: tamamlanmış bir todo'yu tekrar tamamlamak 409 yerine 500 dönüyor.
```

### Devam et (session yarıda kaldıysa)

```text
Continue TODO-001.
```
```text
TODO-001'e devam et.
```

### Durum sor (değişiklik yapmaz)

```text
What is the state of TODO-001?
```
```text
TODO-001 hangi aşamada?
```

### Araştırma / soru (run gerektirmez)

```text
Explain how todo persistence is layered; do not change anything.
```
```text
Todo persistence'ın katmanlarını açıkla; hiçbir şeyi değiştirme.
```

### Bitmiş işin devamı (yeni task)

```text
Follow up on TODO-001: reject titles longer than 200 characters.
```
```text
TODO-001'in devamı: 200 karakterden uzun başlıkları reddet.
```

### Teslim (açık yetki)

```text
Commit the completed TODO-001 work and push it.
```
```text
Tamamlanan TODO-001 işini commit'le ve push'la.
```

### Bırak

```text
Stop TODO-001; it is blocked on an unavailable database.
```
```text
TODO-001'i bırak; erişilemeyen veritabanı yüzünden bloke.
```

### Sen bildiğin bir kısıt eklemek istersen

Kısıtı cümleye ekle; workflow'u tarif etme:

```text
Add tag filtering to GET /api/v1/todos without adding a new dependency.
```
```text
GET /api/v1/todos'a tag filtresi ekle; yeni bağımlılık ekleme.
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

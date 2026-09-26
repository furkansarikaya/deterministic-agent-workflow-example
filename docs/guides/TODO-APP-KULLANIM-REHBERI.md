# Deterministic Agent Workflow — Todo App Uygulama Rehberi

Bu rehber, bu repository'nin control plane'ini (`AGENTS.md`, `CLAUDE.md`, `.agents/`, `scripts/agent.sh`) gerçek bir projeye nasıl adapte edeceğini **TodoFlow** örneğiyle gösterir. Günlük kullanım, prompt kuralı ve rollerin ayrıntısı için: [Agent Session ve Prompt Rehberi](AGENT-SESSION-VE-PROMPT-REHBERI.md). Task yönetimi: [Linear](TODO-APP-LINEAR-ORNEGI.md) veya [Markdown](TODO-APP-MARKDOWN-PROJE-YONETIMI.md). Kısa liste: [Entegrasyon checklist'i](YENI-PROJE-ENTEGRASYON-CHECKLIST.md).

TodoFlow: .NET 9 Web API, PostgreSQL, EF Core, xUnit. Kullanıcı todo oluşturur, listeler, tamamlar, siler. Örneğin amacı Todo uygulamasını öğretmek değil; workflow parçalarının birlikte nasıl çalıştığını göstermektir.

---

## 1. Neyi kopyalar, neyi projeye göre yazarsın?

Golden reference'tan kopyala:

```text
AGENTS.md  CLAUDE.md  .agents/  scripts/agent.sh  scripts/worker-run.sh  scripts/wiki-lint.sh  .gitignore (.agents/runs/ satırı)
```

Sonra projeye göre yaz:

| Dosya | İçerik |
|---|---|
| `AGENTS.md` | Projeye özel adapter: proje amacı, repository yapısı, katman sınırları, bağımlılık politikası. Ortak workflow'u tekrar **yazma**; `.agents/WORKFLOW.md`'ye yönlendir. |
| `CLAUDE.md` | Claude'a özel davranış ve proje bağlamı. `AGENTS.md` ile çelişme; kopyası olma. |
| `.agents/ENGINEERING.md` | Mimari yön, kodlama, persistence, API, test kuralları. |
| `.agents/VERIFICATION.md`, `scripts/verify.sh` | Projenin gerçek build/test/lint komutları. |
| `.agents/VIBECOSYSTEM.md` | Yalnız gerçekten kurulu capability'ler. |
| `.agents/config.yaml` | `default_topology` (`standalone` veya `orchestrated`), `canonical_branch`, `knowledge_scope_root`; `pipelines:` tablosu genellikle olduğu gibi kalır. |
| `docs/wiki/` | Mevcut LLM Wiki skill'i ile proje bilgisi (task board değil). |

`AGENTS.md` örneği (yalnız projeye özel kısım):

```md
# TodoFlow agent instructions

Follow `.agents/WORKFLOW.md` for task execution. Do not restate it here.

## Project
TodoFlow is a .NET 9 REST API for managing user todos.

## Repository structure
- `src/TodoFlow.Api` — HTTP layer; `Application` — use cases; `Domain` — model; `Infrastructure` — EF Core/PostgreSQL
- `tests/TodoFlow.UnitTests`, `tests/TodoFlow.IntegrationTests`

## Project rules
- Nullable reference types stay enabled; no new NuGet package unless TASK allows it.
- Endpoints hold no business logic; domain invariants live in Domain.
- Schema changes require an EF migration; public API changes require tests.
- Verification is `./scripts/verify.sh`.
```

`.agents/ENGINEERING.md` örneği:

```md
# TodoFlow engineering rules
Dependency direction: Api → Application → Domain; Infrastructure implements Application/Domain interfaces.
Domain must not reference Infrastructure or ASP.NET Core. Validate external input before state mutation.
Do not expose EF entities directly. Use migrations for schema changes.
Do not rename unrelated types, reorganize directories, or upgrade packages unless TASK requires it.
```

`scripts/verify.sh` (gerçek komutlarına göre):

```sh
#!/bin/sh
set -eu
dotnet restore
dotnet build --no-restore
dotnet test --no-build
```

---

## 2. Başlamadan önce

```sh
./scripts/agent.sh status     # beklenen: active_task=none, implementation_allowed=false
./scripts/verify.sh
./scripts/agent.sh test       # control plane kendi self-test'leri (birkaç dakika)
```

`ACTIVE_RUN` boş olmalıdır; boş selector geçerli "task yok" durumudur ve implementation'ı bloklar. Repository'de tamamlanmış run örneği **yoktur**: `.agents/runs/` geçici çalışma alanıdır, gitignore'dadır ve task bitince `agent.sh cleanup` ile silinir.

---

## 3. Bir task'ı başlatmak

Task'ı tek cümleyle ver (ayrıntı ve örnekler: [prompt kataloğu](AGENT-SESSION-VE-PROMPT-REHBERI.md#6-prompt-kataloğu)):

```text
Work on docs/project/tasks/TODO-001.md.
```
```text
docs/project/tasks/TODO-001.md task'ı üzerinde çalış.
```

Gerisini agent, `AGENTS.md`'deki boot protocol ile yapar: run dizinini şablonlardan oluşturur ve aktive eder, task'ı sınıflandırır, task branch'ini açar, baseline alır, DISCOVER'ı read-only yürütür, sınıfın gerektirdiği evidence/plan/QA planını üretip dondurur, tek worker ile implemente eder, bağımsız gate'leri geçirir, completion report'u yayınlar ve run'ı temizleyip durur.

### TODO-001 (`Create todo`) için ne beklenir?

Sınırlı, tek bileşenli bir endpoint olduğu için sınıf **STANDARD**'dır: `EVIDENCE.md` (repository'deki mevcut katman ve pattern'ler; wiki yalnız gerekirse), `PLAN.md` (YAML `scope:` yolları ve her yolun acceptance kriteri), `QA_PLAN.md` (başlık zorunlu, boş başlık reddi, HTTP 201, kalıcılık), sonra QA ve VERIFY gate'leri. Auth eklenseydi CRITICAL, birden fazla katmanı ve migration'ı değiştiren bir iş COMPLEX olurdu ve REVIEW gate'i de zorunlu hale gelirdi. TDD kanıtı (RED sonra GREEN) her scope yolu için gerekir; RED/GREEN'in gerçekten uygulanamadığı yol için PLAN'da gerekçeli `tdd_exemption` yazılır.

### Ne değişmez, ne değişebilir?

- **Frozen** TASK, EVIDENCE, PLAN ve QA_PLAN sonradan sessizce değişmez; eksik bilgi amendment + `refreeze` ister.
- Task kaynağının (`TODO-001.md`) sözleşme kısmı freeze'den sonra değişirse `freshness` bloklar; yalnız `Status` satırı ve yayınlanan completion report bloğu bookkeeping'dir.
- Kapsam dışı bir dosyaya ihtiyaç doğarsa implementer durur ve Orchestrator karar verir.

---

## 4. Bitiş

`CODE_DONE` yalnız gerekli gate'lerin final ağaç üzerinde geçtiğini söyler. `DONE` için ayrıca knowledge adımı (`not_applicable` olabilir), gerçek run kanıtından türetilmiş `COMPLETION_REPORT.md` ve onun task kaynağına yayınlanıp doğrulanması gerekir. Ardından:

```sh
./scripts/agent.sh delivery-check TODO-001   # yerel teslim hazırlığı; uzaktan bir şey yapmaz
./scripts/agent.sh cleanup TODO-001          # run dizini silinir, ACTIVE_RUN boşalır
```

Commit/push/PR ve task-system yazımı senin ayrı ve açık yetkinle yapılır. Kalıcı kayıt: task dosyasındaki completion report, kod/test ve Git geçmişi; wiki yalnız kalıcı bir sözleşme veya karar değiştiyse güncellenir.

---

## 5. Üç ayrı alan

```text
docs/project/  veya  Linear   → ne yapılacak? (task yönetimi)
.agents/runs/<TASK>            → bu iş şu an nasıl güvenli yürütülüyor? (geçici execution state)
docs/wiki/                     → proje bunu neden böyle biliyor/yapıyor? (kalıcı bilgi)
```

Birbirinin yerine geçmezler. Wiki sprint board değildir; run kalıcı arşiv değildir; task dosyası execution state tutmaz. Ayrıntı: [Markdown](TODO-APP-MARKDOWN-PROJE-YONETIMI.md), [Linear](TODO-APP-LINEAR-ORNEGI.md).

---

## 6. Token / context disiplini

Agent yalnız aktif task'ı ve ilgili repository/test kanıtını okur. Yüklemez: tüm `.agents/**`, tüm `docs/wiki/**`, tüm backlog/sprint/Linear geçmişi, session geçmişi. Kontrol belgeleri yalnız işlemin ihtiyaç duyduğunda yüklenir; wiki'ye index'ten başlanır ve yalnız task/repository/test cevap vermiyorsa bakılır. Explorer'lar ham dosya içeriği değil, kaynak referanslı kısa bulgu döndürür; Reviewer'ın bağlamı task/kriter, frozen plan referansları ve ilgili diff/testlerdir, Verifier'ınki daha da dardır. Sub-agent'ların toplam token'ı garanti olarak azalttığı iddia edilmez; amaç ana bağlamı temiz ve tekrarlı araştırmayı az tutmaktır.

---

## 7. Kontrol listeleri

**Bir kerelik:** `AGENTS.md`/`CLAUDE.md` projeye özel; `ENGINEERING.md`, `VERIFICATION.md`, `verify.sh` gerçek komutlar; `config.yaml` topology/branch; `.gitignore`'da `.agents/runs/`; `ACTIVE_RUN` boş; `agent.sh status` ve `agent.sh test` geçiyor; wiki başlatıldı; task kaynağı seçildi.

**Her task için (agent yapar, sen kontrol edersin):** doğru sınıf (`agent.sh pipeline <ID>`); frozen scope acceptance kriterlerine bağlı; gerekli gate'ler final ağaçta geçti; `delivery-check` temiz; completion report yayınlandı; run temizlendi; teslim için açık yetkin verildi.

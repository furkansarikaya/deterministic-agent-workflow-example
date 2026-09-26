# Deterministic Agent Workflow — Yeni Projeye Entegrasyon Checklist'i

Ayrıntılı anlatım: [Todo App Uygulama Rehberi](TODO-APP-KULLANIM-REHBERI.md). Günlük kullanım ve prompt'lar: [Agent Session ve Prompt Rehberi](AGENT-SESSION-VE-PROMPT-REHBERI.md).

## Kopyala

```text
AGENTS.md  CLAUDE.md  .agents/  scripts/agent.sh  scripts/worker-run.sh  scripts/wiki-lint.sh
.gitignore içinde  .agents/runs/
```

## Projeye göre düzenle

- [ ] `AGENTS.md`: proje amacı, layout, katman sınırları, bağımlılık politikası, stack kuralları. Ortak workflow'u kopyalama; `.agents/WORKFLOW.md`'ye yönlendir.
- [ ] `CLAUDE.md`: Claude'a özel bağlam ve capability sınırları; `AGENTS.md` ile çelişme.
- [ ] `.agents/ENGINEERING.md`: mimari yön, kodlama/persistence/API/test kuralları, opportunistic refactor yasağı.
- [ ] `.agents/VERIFICATION.md` ve `scripts/verify.sh`: gerçek build/test/lint/security komutları.
- [ ] `.agents/VIBECOSYSTEM.md`: yalnız gerçek kurulu capability'ler.
- [ ] `.agents/config.yaml`: `default_topology`, `canonical_branch`, `knowledge_scope_root`; `pipelines:` tablosunu bilinçli değiştirmeden bırak.
- [ ] `docs/wiki/`: mevcut LLM Wiki skill'i ile başlat; task yönetimi için kullanma.
- [ ] Task kaynağı: Markdown (`docs/project/tasks/<ID>.md`, yerleşik `markdown` adapter'ı) veya Linear (kendi adapter'ını yaz).

## Doğrula

- [ ] `./scripts/agent.sh status` → `active_task=none` (boş `ACTIVE_RUN` normaldir).
- [ ] `./scripts/verify.sh` ve `./scripts/agent.sh test` geçiyor.
- [ ] Repository'de tamamlanmış run yok; `.agents/runs/` yalnız geçici ve gitignore'da.

## İlk kullanım

Tek cümleyle başlat (örnekler: prompt kataloğu):

```text
Work on docs/project/tasks/TODO-001.md.
```

Agent boot protocol'ü izler: run oluşturur, sınıflandırır, branch açar, baseline alır, gerekli artifact'ları dondurur, tek worker ile implemente eder, bağımsız REVIEW/QA/VERIFY gate'lerini geçirir, completion report'u yayınlar, `delivery-check` yapar, run'ı temizler ve durur. Commit/push/PR için ayrıca açık yetki verirsin.

## Roller ve topology

- [ ] Varsayılan `full_lifecycle` (Orchestrator); Claude Code ve Codex standalone kullanabiliyor.
- [ ] `default_topology` bilinçli seçildi: `standalone` (Orchestrator RED/GREEN'i yazar) veya `orchestrated` (yalnız `implementation_worker` uygulama kodunu yazar, `scripts/worker-run.sh` ile).
- [ ] REVIEW/QA/VERIFY bağımsız rollerden geliyor; implementation kendini onaylamıyor.
- [ ] Worker gate kaydetmiyor, DONE ilan etmiyor, delivery yapmıyor, başka agent çağırmıyor.
- [ ] Sub-agent'lar bounded; swarm ve recursive delegation yok; implementation tek worker.

## Anti-pattern'ler

- Her task'ta tüm `.agents` dosyalarını, tüm wiki'yi veya tüm backlog'u okutmak.
- Prompt'a lifecycle adımlarını, delegation talimatlarını veya stop koşullarını yazmak.
- Linear/Markdown task'ı ile `.agents/runs`'ı aynı şey sanmak; wiki'yi sprint board yapmak.
- Run dizinini commit etmek veya bitmiş run'ı arşivlemek.
- `CLAUDE.md`'yi `AGENTS.md` kopyası yapmak.
- Verification yerine agent'ın "bitti" demesine güvenmek.

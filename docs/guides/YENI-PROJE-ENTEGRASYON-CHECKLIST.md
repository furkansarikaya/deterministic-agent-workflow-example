# Deterministic Agent Workflow — Yeni Projeye Entegrasyon Checklist'i

## Kopyala

Golden reference'tan:

```text
AGENTS.md
CLAUDE.md
.agents/
scripts/agent.sh
scripts/wiki-lint.sh
```

## Projeye göre düzenle

### AGENTS.md

Ekle:

- proje amacı
- repository layout
- architecture boundaries
- dependency policy
- stack-specific coding rules
- task-specific olmayan kalıcı repository kuralları

Shared workflow'u kopyalayıp büyütme.

### CLAUDE.md

Ekle:

- Claude Code'a özel proje context'i
- kullanılabilecek vibecosystem capabilities
- deterministic mode'da kapalı/izinli Claude özellikleri
- progressive-disclosure davranışı

AGENTS ile çelişme.

### `.agents/ENGINEERING.md`

Ekle:

- architecture dependency direction
- coding conventions
- persistence rules
- API rules
- testing rules
- no-opportunistic-refactor kuralları

### `.agents/VERIFICATION.md`

Gerçek build/test/lint/security komutlarını yaz.

### `scripts/verify.sh`

Projenin gerçekten kullandığı komutları çalıştır.

### `.agents/VIBECOSYSTEM.md`

Yalnız gerçek kurulu capability isimlerini ve mode/profile sınırlarını yaz.

Vibecosystem'i burada yeniden implement etme.

### `docs/wiki`

Mevcut LLM Wiki skill'i ile proje semantic memory'sini başlat.

Wiki'yi task management için kullanma.

## Seç: task management

### Linear

```text
Linear issue
→ .agents/runs/<ISSUE-ID>
```

### Markdown

```text
docs/project/tasks/<TASK-ID>.md
→ .agents/runs/<TASK-ID>
```

## İlk kullanım

1. `ACTIVE_RUN` boş olduğunu doğrula.
2. İlk task'ı tanımla.
3. Run oluştur.
4. Run'ı aktive et.
5. Baseline al.
6. DISCOVER.
7. EVIDENCE.
8. PLAN.
9. Freeze.
10. Implement.
11. Verify.
12. Review.
13. CODE DONE.
14. Task status güncelle.
15. Gerekliyse wiki ingest/lint.
16. KNOWLEDGE DONE.

## Execution role adoption

- [ ] Varsayılan `full_lifecycle` execution tanımlı.
- [ ] Claude standalone `full_lifecycle` kullanabiliyor.
- [ ] Codex standalone `full_lifecycle` kullanabiliyor.
- [ ] Açık `implementation_worker` invocation tanımlı.
- [ ] Worker later lifecycle phase'lerini, delivery'yi ve delegation'ı sahiplenmiyor.
- [ ] Cross-agent resume ile delegated implementation farklı kavramlar olarak dokümante edildi.

## Anti-pattern'ler

Yapma:

- her task'ta bütün `.agents` dosyalarını okutmak
- bütün wiki'yi okutmak
- bütün backlog'u context'e taşımak
- Linear ve `.agents/runs`'ı aynı şey sanmak
- wiki'yi sprint board'a çevirmek
- CLAUDE.md'yi AGENTS.md kopyası yapmak
- golden reference'taki example run'ı gerçek active task olarak bırakmak
- verification yerine agent'ın "bitti" demesine güvenmek

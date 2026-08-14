# 00 — Ideation Blueprint

## 1. The problem, precisely stated

A primary school teacher preparing a monthly assessment currently:

1. Opens the official textbook and the ministry syllabus (often two separate PDFs, sometimes paper).
2. Recalls which lessons were actually covered since the last assessment.
3. Hand-writes or copy-pastes exercises from the textbook, past papers, or teacher Facebook groups.
4. Re-types everything into Word, fights with tables, RTL text, and image placement.
5. Writes a separate answer key, usually by hand, often inconsistent with the final paper.

This costs **2–5 hours per exam**, is **not verifiably aligned** to the official learning objectives,
and produces **non-reusable artefacts**. Generic AI chatbots do not solve this: they hallucinate
content outside the year's program, ignore the ministry's pedagogical vocabulary, cannot lay out a
printable bilingual paper, and produce no answer key that is guaranteed consistent with the paper.

**Product thesis:** the value is not "an LLM writes questions". The value is
**grounding + curation + artefact quality**. The LLM is one replaceable component inside a
curriculum-constrained pipeline.

---

## 2. Personas

| Persona | Context | Primary need | Success signal |
|---|---|---|---|
| **Amira — Year 2 generalist** | Teaches all subjects to one class of 28. Low tech confidence. Arabic + French. | "Give me a ready paper for the chapters I actually taught, in 10 minutes." | Exports a usable PDF on first attempt without editing question text |
| **Karim — Year 6 subject lead** | Teaches Maths/Sciences across 3 classes, prepares the end-of-cycle exam. High standards. | Fine control: difficulty mix, cognitive levels, problem-solving weighting. | Builds a bank he reuses and re-mixes across 3 classes |
| **Ms. Ben Salah — School coordinator** | Reviews papers for consistency across parallel classes. | Evidence of coverage: which objectives does this paper actually test? | Uses the coverage report to sign off |
| **Ministry / curriculum admin** *(internal)* | Loads official books each school year. | Ingest a new textbook edition without engineering help. | New edition live and queryable after upload + review |

**Anti-persona (explicitly not served now):** secondary/high school, private tutoring marketplaces,
student-facing self-study.

---

## 3. Jobs-to-be-done

- **JTBD-1** — *When* I've finished chapters 3–5 of Year 4 Sciences, *I want* a question pool tied to
  exactly those chapters, *so I can* assess without testing untaught material.
- **JTBD-2** — *When* I need a 45-minute paper, *I want* to control question count, type mix and
  difficulty, *so that* the paper fits the period and my class's level.
- **JTBD-3** — *When* the exercise needs a picture (vocabulary illustration, 7 apples to count, a
  plant-parts diagram), *I want* the image generated and placed, *so I* don't hunt Google Images.
- **JTBD-4** — *When* the paper is done, *I want* a clean printable PDF **and** a matching answer key,
  *so I* can print and grade.
- **JTBD-5** — *When* next term comes, *I want* to reuse and remix my previous banks, *so I* don't
  start from zero.
- **JTBD-6** — *When* my inspector asks, *I want* proof each question maps to an official objective,
  *so I* can justify the assessment.

---

## 4. Product principles

1. **Grounded or nothing.** Every generated exercise carries citations to `curriculum_node` +
   `source_chunk` IDs. Ungrounded output is a validation failure, not a warning.
2. **Teacher is the author, AI is the intern.** The system always produces a *pool*, never a final
   paper. The teacher's pick/mix/reorder step is mandatory by design.
3. **Backend-driven.** All state, ordering, numbering, scoring and rendering live server-side. The
   frontend is a thin view over `GET /exams/{id}`. This keeps mobile/desktop/print consistent and
   makes the whole product API-first.
4. **Provider-agnostic AI.** Text and image models sit behind `LLMProvider` / `ImageProvider`
   interfaces. Swapping OpenAI → Anthropic → a local Llama is a config change.
5. **Everything is reusable.** Exercises are first-class rows, not blobs inside an exam. An exam is
   an *ordered selection* of exercise versions.
6. **Print is the real UI.** A beautiful web preview that prints badly is a failed feature.

---

## 5. Feature scope matrix

| # | Capability | Phase | Notes |
|---|---|---|---|
| F1 | Curriculum tree browse (year → subject → unit → chapter → objective) | MVP | Read-only, seeded by ingestion |
| F2 | Textbook ingestion pipeline (PDF → chunks → embeddings) | MVP | Admin-triggered, human review gate |
| F3 | Custom chapter upload (teacher pastes text / uploads PDF/DOCX) | MVP | Scoped to one generation session |
| F4 | MCP server exposing curriculum Resources/Tools/Prompts | MVP | The agent's only route to curriculum data |
| F5 | Exercise pool generation with preference tuning | MVP | Difficulty, count, types, language, focus |
| F6 | Exercise types: MCQ, fill-blank, matching, true/false, short answer, open-ended, problem-solving, ordering, labelling | MVP | 9 types, extensible registry |
| F7 | Validation/critic pass (curriculum fit, age fit, answer correctness, duplicate detection) | MVP | Blocks bad items pre-display |
| F8 | Interactive pick/mix exam builder | MVP | Reorder, edit inline, set marks |
| F9 | Image generation for visual exercises | MVP | Prompt-guarded, cached, moderated |
| F10 | PDF + DOCX export, paper + answer key | MVP | Server-rendered |
| F11 | Coverage report (objectives tested, Bloom distribution, marks balance) | v1.1 | Coordinator value |
| F12 | Personal + school-shared exercise banks | v1.1 | |
| F13 | Regenerate single exercise / "more like this" | v1.1 | |
| F14 | Variant generation (Form A / Form B anti-cheat) | v1.2 | Same objectives, different surface |
| F15 | Differentiated papers (support / core / extension) | v1.2 | |
| F16 | Analytics: item difficulty from real class results | v2 | Requires results capture |
| F17 | Auth, schools, roles, sharing permissions | **Deferred** | `[AUTH-LATER]` hooks in place |

---

## 6. Primary user journey (happy path)

```
1. START          Teacher opens "New exam"
2. SCOPE          Picks Year 4 → Sciences → Unit 2 → chapters "Plant nutrition", "Photosynthesis"
                  (or switches to "Upload my own chapter" and pastes text)
3. TUNE           Language: French · Difficulty: Medium (60%) / Hard (20%) / Easy (20%)
                  · 12 questions · types: MCQ, matching, short answer, problem-solving
                  · pedagogical focus: "comprehension + application, avoid pure recall"
                  · allow images: yes
4. GENERATE       POST /generation-jobs → async job
                  Agent: resolve scope → MCP retrieve → plan blueprint → synthesize → validate
                  → queue image jobs → persist pool (typically 25–35 candidates for 12 slots)
5. CURATE         Teacher browses pool, filters by type/difficulty/objective, previews images,
                  selects 12, drags to reorder, edits a stem inline, sets marks per item
6. PREVIEW        GET /exams/{id}/preview → server-rendered HTML mirroring print layout
7. EXPORT         POST /exams/{id}/exports {format: pdf, include_answer_key: true}
                  → paper.pdf + answer_key.pdf (or single merged doc)
8. REUSE          Exam + its exercises stay in the teacher's bank, cloneable next term
```

**Latency budget:** step 4 returns a job in <300 ms; first candidates stream in ~8 s; full pool
≤45 s; images resolve asynchronously and back-fill (placeholder shown meanwhile). Export ≤6 s.

---

## 7. Alternate & edge journeys

- **Custom chapter path** — teacher uploads a non-ministry text. System still generates, but flags
  the exam `grounding: custom_source` and the coverage report says "not verified against official
  program". Honest labelling preserves trust in the grounded path.
- **Thin curriculum coverage** — a chapter with too few source chunks. Agent returns partial pool +
  `warnings: [LOW_SOURCE_COVERAGE]` rather than hallucinating filler.
- **Image generation fails / moderation blocks** — exercise stays usable with a text-only fallback and
  an "image unavailable" state; never blocks the export.
- **Year 1 / pre-literate constraints** — for Year 1–2, generator is hard-constrained: short sentences,
  vocabulary whitelist from the textbook, image-heavy, no multi-step problem solving.
- **Mixed-language paper** — e.g. Arabic instructions with French vocabulary items. Language is
  per-exercise, not just per-exam.

---

## 8. Differentiation vs. "just use ChatGPT"

| Dimension | Generic chatbot | ExamForge |
|---|---|---|
| Curriculum fidelity | Plausible-sounding, unverifiable | Retrieval from the actual ministry book, with citations per item |
| Scope control | Prompt-hope | Hard filter on curriculum node IDs; retrieval cannot leave the selected chapters |
| Answer key | Ad hoc, drifts from paper | Generated as part of the same item record; guaranteed consistent |
| Layout | Copy-paste into Word | Server-rendered print-grade PDF/DOCX, RTL-aware |
| Images | None / mismatched | Generated to a spec derived from the exercise (countable objects, labelled diagrams) |
| Reuse | Lost in chat history | Structured bank, versioned, remixable |
| Pedagogical rigour | Random Bloom distribution | Blueprint-driven: explicit cognitive-level and marks targets |

---

## 9. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Textbook copyright | High | Ingest under ministry agreement; store chunks for retrieval-grounding, never reproduce long verbatim passages in output; generated items must be *original* — enforced by an n-gram overlap check against source chunks (>12-gram match ⇒ rejected) |
| Hallucinated facts in Sciences/History | High | Mandatory citation + critic pass + "unsupported claim" detector; teacher curation as final gate |
| Wrong answer in the key | High | Critic model re-solves each item independently; disagreement ⇒ item flagged `needs_review`, never silently shipped |
| Model cost blowout | Medium | Blueprint-then-batch generation (1 planning call + batched synthesis), aggressive semantic caching, per-teacher quotas |
| Provider outage | Medium | Provider abstraction + ordered fallback chain + circuit breaker |
| Image inappropriateness | Medium | Prompt templating (no free-text passthrough), provider moderation, deny-list, cached-approved-asset preference |
| Poor RTL/Arabic typography | Medium | Dedicated font stack + shaping in the render service; golden-image regression tests on export |
| Teacher distrust of AI | Medium | Never auto-submit a paper; show citations; label unverified sources |

---

## 10. Success metrics

**North star:** *Exported exams per active teacher per term.*

| Layer | Metric | Target |
|---|---|---|
| Activation | % of generation jobs reaching export | ≥ 55% |
| Quality | % of pool items selected by teacher (pool yield) | ≥ 35% |
| Quality | % of selected items edited before export | ≤ 30% |
| Trust | Items flagged incorrect by teachers | < 3% |
| Speed | Median scope → export wall-clock | < 12 min |
| Cost | Model spend per exported exam | < $0.15 |
| Reliability | Export job success rate | ≥ 99.5% |

---

## 11. Phased roadmap

- **Phase 0 — Curriculum spine (2 sprints).** Ingestion pipeline, curriculum tree, admin review UI,
  embeddings. No generation yet. *Exit:* one full year+subject queryable with objectives.
- **Phase 1 — MCP + generation core (3 sprints).** MCP server (resources/tools/prompts), agent
  orchestrator, 9 exercise types, validation pass, pool persistence. *Exit:* pool for any seeded
  chapter, ≥80% items pass validation.
- **Phase 2 — Builder + export (2 sprints).** Pick/mix/reorder, inline edit, marks, preview,
  PDF/DOCX with answer key. *Exit:* end-to-end journey.
- **Phase 3 — Multimodal (2 sprints).** Image spec extraction, provider integration, async back-fill,
  asset cache, moderation. *Exit:* visual exercises in export.
- **Phase 4 — Scale & trust (ongoing).** Coverage reports, banks, variants, differentiation,
  `[AUTH-LATER]` identity, analytics.

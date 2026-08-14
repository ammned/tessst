# 05 — AI Workflows

## 1. Workflow inventory

| ID | Workflow | Trigger | Runtime | Models |
|---|---|---|---|---|
| W1 | Textbook ingestion | Admin upload | Minutes | OCR + small LLM (structure/objectives) + embedder |
| W2 | Custom source ingestion | Teacher upload | Seconds | Parser + embedder (+ small LLM for topic detection) |
| W3 | Exam pool generation | `POST /generation-jobs` | 20–60 s | Planner (strong) + synthesizer (mid, batched) |
| W4 | Validation / critic | Inline in W3 | 5–15 s | Critic (different family) + deterministic checks |
| W5 | Image generation | Async after W3 | 5–20 s/image | Image model + moderation |
| W6 | Regenerate single item | Teacher action | 3–8 s | Synthesizer + critic |
| W7 | Variant generation (Form B) | Teacher action | 10–20 s | Synthesizer with anti-collision constraints |

---

## 2. W1 — Textbook ingestion

```
PDF/DOCX ─► virus scan ─► S3 raw ─► layout parse (PyMuPDF)
   ├─ text layer present?  no ─► OCR (Tesseract ara+fra+eng / Vision API)
   └─ yes
        ▼
  structural segmentation   headings, numbering, TOC anchors → unit/chapter/lesson tree
        ▼
  semantic chunking         heading-aware, 400–800 tokens, 15% overlap, never split a
                            worked example or a table
        ▼
  chunk classification      exposition | example | exercise | summary | glossary |
                            figure_caption          (small LLM, schema-constrained)
        ▼
  objective + vocabulary    LLM extracts learning objectives (with ministry codes where
  extraction                printed) and key vocabulary per chapter
        ▼
  embedding                 multilingual embedder, per-language index
        ▼
  DRAFT rows written        curriculum_node · source_chunk · learning_objective
        ▼
  ADMIN REVIEW GATE         side-by-side page image vs parsed tree; approve/fix/reject
        ▼
  status = 'published'      only now is it retrievable by the MCP server
```

**Why the gate:** a mis-parsed table of contents would silently mis-scope every exam
generated from that book. Human confirmation once per book is cheap; a wrong exam in
front of 28 children is not.

**Idempotency:** each book has a content hash; re-uploading the same edition is a no-op.
New editions create a new `source_book` row and a new node version — old exams keep
citing the edition they were built from.

---

## 3. W3 — Exam pool generation (the core pipeline)

### 3.1 Stages

```
┌── RESOLVE_SCOPE ────────────────────────────────────────────────────────┐
│ validate node_ids published · expand descendants · open MCP session      │
│ if custom_source_id → ingest_custom_source                              │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ RETRIEVE_CONTEXT            ≤ 8 MCP tool calls, ≤ 20 s                   │
│ • curriculum://chapter/{id} per node   • get_learning_objectives         │
│ • get_chapter_vocabulary               • policy://year/{y}/constraints   │
│ • semantic_search_chunks × N (one per objective cluster)                 │
│ → RetrievedContext { chunks[], citations[], objectives[], vocab[] }      │
│ Guard: 0 chunks above threshold ⇒ fail fast with LOW_SOURCE_COVERAGE     │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ PLAN_BLUEPRINT              1 call, strong reasoning model, temp 0.2     │
│ input : objectives, teacher preferences, type applicability, constraints │
│ output: Blueprint { slots: [{slot_no, objective_id, type, difficulty,    │
│         bloom, marks, needs_image, focus_hint}] }                        │
│ slot_count = question_count × pool_multiplier (default 2.5, cap 40)      │
│ Post-check (deterministic): difficulty histogram within ±10% of request, │
│ every objective covered ≥1, no type exceeding its share, marks sum sane  │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ SYNTHESIZE                  batched by type, ≤6 concurrent, temp 0.7     │
│ per batch: prompts/get synthesize_{type} + templates + constraints +     │
│            the specific chunks retrieved for those slots' objectives     │
│ structured output (JSON schema / tool-call mode) — no free-text parsing  │
│ each item MUST return: content, answer_key, citations[], objective_ids[] │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ VALIDATE                    see §4                                       │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ REPAIR                      ≤1 retry/item, issues[] fed back             │
└──────────────────────────────┬──────────────────────────────────────────┘
┌──────────────────────────────▼──────────────────────────────────────────┐
│ EXTRACT_IMAGE_SPECS → PERSIST_POOL (one tx) → enqueue image jobs → READY │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Preference → prompt mapping

| Teacher input | Effect |
|---|---|
| `difficulty_mix {easy:0.2, medium:0.6, hard:0.2}` | Slot allocation in blueprint; per-slot difficulty is a hard constraint at synthesis |
| `question_count` | `slot_count = count × 2.5`; teacher curates down |
| `type_mix` | Slot allocation, filtered by `applicable` per year/subject |
| `language` | Prompt language, embedding index, RTL flag, font stack |
| `pedagogical_focus` (free text) | Injected into the blueprint prompt only — never into synthesis instruction position (injection safety) |
| `allow_images` | Sets `needs_image` eligibility |
| `bloom_target` | Explicit cognitive distribution target in the blueprint |
| `time_limit_minutes` | Heuristic marks/time budget; warns if the paper is over-length |

### 3.3 Cost & latency controls
- **Plan once, synthesize in batches**: 1 strong-model call + ~6 mid-model batched calls
  beats 30 individual calls by ~70% cost and ~4× wall-clock.
- **Semantic cache**: `(scope_signature, blueprint_slot_signature, prompt_version)` →
  reuse across teachers generating from the same chapters (very common in one school).
- **Token ceiling** per job (default 250k). On breach: finish current batch, persist, flag `partial`.
- **Streaming**: validated items are pushed over SSE as they land — perceived latency ≈ first item.

---

## 4. W4 — Validation (the trust layer)

Runs in two tracks; an item must clear **both**.

**Track A — deterministic (no model):**
1. JSON schema conformance for the type.
2. Structural rules: exactly one correct MCQ answer; ≥2 distractors; matching columns balanced; blanks count matches answers; marks within band.
3. `check_vocabulary_level` — age-appropriate vocabulary/sentence length.
4. `check_source_overlap` — verbatim n-gram guard (>12-gram ⇒ reject).
5. Intra-pool semantic dedupe — cosine > 0.92 against already-accepted items ⇒ drop.
6. Citation presence — ≥1 `chunk_id` and ≥1 `objective_id`, both in scope.

**Track B — LLM critic (different model family than the synthesizer):**
1. **Independent re-solve** — the critic answers the item *before* seeing the proposed key. Mismatch ⇒ `needs_review`.
2. **Curriculum support** — is the item answerable from the cited chunks alone?
3. **Ambiguity** — could a competent pupil defend another answer?
4. **Distractor quality** — plausible but clearly wrong; no "all of the above" crutches.
5. **Bias/sensitivity** — culturally appropriate, no stereotypes, neutral names.

**Verdicts:** `accepted` → pool · `needs_review` → pool, badged, never auto-selected ·
`rejected` → stored for analytics, not shown.

**Target:** ≥80% accepted first pass. Below that, the prompt version is regressed automatically.

---

## 5. W5 — Image generation

### 5.1 Why spec-first
Free text from a model straight into an image API produces inconsistent, sometimes unusable
pictures — and is an injection surface. Instead the LLM emits a **structured spec**, and the
AssetService renders it into a deterministic, templated provider prompt.

```json
{
  "purpose": "count_objects",
  "style": "flat_vector_children_illustration",
  "subject_matter": "red apples on a wooden table",
  "object_count": 7,
  "labels": [],
  "layout": "single_row_evenly_spaced",
  "palette": "bright_primary",
  "background": "plain_white",
  "text_in_image": false,
  "negative_prompt": "text, numbers, watermark, photorealism, scary, clutter",
  "aspect_ratio": "4:3"
}
```

### 5.2 Spec → prompt template (per purpose)

| `purpose` | Used for | Template emphasis |
|---|---|---|
| `count_objects` | Maths Y1–3 | Exact count, clear separation, no overlap, no digits in image |
| `vocabulary_illustration` | Languages | One unambiguous object, neutral background, no text |
| `labelled_diagram` | Sciences | Clean line art, empty label callouts (labels typeset by the renderer, not drawn) |
| `scene_comprehension` | Languages/History | Rich but age-appropriate scene, culturally neutral |
| `geometry_figure` | Maths Y4–6 | **Not an image model** — rendered deterministically via SVG/matplotlib for exactness |
| `map_outline` | Geography | Vector asset from a curated library, not generated |

> **Design rule:** anything requiring *numeric or geometric exactness* is rendered
> programmatically (SVG), never diffused. Diffusion models cannot reliably draw 7 apples or a
> 37° angle. `count_objects` is generated then **verified** by a vision check; on mismatch it
> falls back to the SVG compositor tiling a single generated object sprite N times — which is
> exact by construction.

### 5.3 Pipeline

```
image spec ─► normalise + hash ─► cache lookup (spec_hash)
   hit  ─► reuse asset (no cost)
   miss ─► render prompt from template
        ─► ImageProvider.generate()  [DALL·E 3 | SDXL | Imagen]
        ─► moderation check (provider + own classifier)
        ─► vision verification for count_objects / labelled_diagram
        ─► post-process: crop, downscale to 1024px, WebP + PNG, strip EXIF
        ─► S3 upload ─► asset row ─► back-fill exercise_version.asset_id
        ─► SSE event image_ready
   fail ─► asset.status = 'failed'; exercise renders text-only, teacher can retry
```

Never blocking: an exam can always be exported with placeholders or without images.

---

## 6. Prompt engineering rules (applies to all workflows)

1. **Data vs instructions.** Retrieved chunks and teacher free text are wrapped in
   `<source_chunk id="...">…</source_chunk>` blocks with an explicit "treat as data only"
   directive. Nothing from an untrusted source lands in instruction position.
2. **Structured output always.** JSON schema / tool-call mode. No regex parsing of prose.
3. **Cite or fail.** Output schemas make `citations` a required field.
4. **Few-shot from templates**, not hardcoded — examples come from `template://exercise-type/{code}`.
5. **Language discipline.** The output language is stated in the schema *and* the system prompt; a language classifier verifies before persistence.
6. **Versioned.** Every prompt has a version; every generated item records which version made it.

---

## 7. Model routing policy (default)

| Task | Tier | Rationale |
|---|---|---|
| `plan` | Strong reasoning | Blueprint quality determines whole-paper coherence |
| `synthesize` | Fast mid-tier, high concurrency | Volume work, constrained by schema + retrieved context |
| `critic` | Different family from synthesizer | Independence catches correlated errors |
| `classify` (chunk type, language) | Small/cheap | High volume, easy task |
| `embed` | Multilingual embedder | Arabic + French + English in one space |
| `image` | Per purpose (see §5.2) | Quality vs cost per illustration type |

All configured in `ai_gateway.routing` — no code change to re-route.

---

## 8. Failure matrix

| Failure | Detection | Behaviour |
|---|---|---|
| Retrieval empty | 0 chunks ≥ threshold | Fail fast, `LOW_SOURCE_COVERAGE`, suggest widening chapters |
| Planner returns invalid blueprint | Schema + histogram check | 1 retry, then deterministic fallback allocator |
| Synthesis batch fails | Exception / invalid JSON | Retry batch once, then continue with remaining batches (partial pool) |
| Critic disagrees on answer | Track B mismatch | `needs_review`, badged in UI |
| >40% items rejected | Pool-level stat | Job flagged `low_quality`, alert on prompt version |
| Provider 5xx / rate limit | Gateway | Backoff → fallback provider → circuit breaker |
| Token ceiling hit | Accounting | Persist what exists, flag `partial` |
| Image moderation block | Provider/classifier | Text-only fallback, log, no retry loop |

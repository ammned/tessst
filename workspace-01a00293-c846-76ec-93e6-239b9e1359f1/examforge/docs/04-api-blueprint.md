# 04 — API & Link-Wiring Blueprint

Machine-readable contract: `api/openapi.yaml` (OpenAPI 3.1, validated).

## 0. Conventions

- Base path `/api/v1`. JSON everywhere. `snake_case` fields. UUIDv4 ids. UTC ISO-8601 timestamps.
- **Teacher context `[AUTH-LATER]`** — the gateway injects `X-Teacher-Id`. Today it is accepted
  directly (dev stub); when auth lands, the gateway derives it from a verified token and the header
  becomes untrusted-from-clients. **No route changes required.**
- **Long operations** return `202 Accepted` + a job resource + `Location`. Poll `GET` or subscribe to
  `GET …/events` (SSE).
- **Idempotency** — `POST` accepts `Idempotency-Key`; replays return the original result.
- **Concurrency** — mutable resources expose `version`; send `If-Match: "<version>"` → `409` on stale.
- **Pagination** — cursor-based: `?limit=50&cursor=…` → `{items, next_cursor}`.
- **Errors** — RFC 9457 Problem Details:

```json
{ "type": "https://examforge.app/errors/low-source-coverage",
  "title": "Insufficient curriculum coverage",
  "status": 422, "code": "LOW_SOURCE_COVERAGE",
  "detail": "Only 2 source passages found for the selected chapters; need at least 5.",
  "instance": "/api/v1/generation-jobs/2b0f…",
  "hints": ["Select an additional chapter", "Upload your own chapter text"] }
```

**Error codes:** `VALIDATION_ERROR` · `NODE_NOT_FOUND` · `NODE_NOT_PUBLISHED` · `SCOPE_VIOLATION` ·
`LOW_SOURCE_COVERAGE` · `MCP_UNAVAILABLE` · `PROVIDER_UNAVAILABLE` · `TOKEN_BUDGET_EXCEEDED` ·
`JOB_NOT_READY` · `EXAM_EMPTY` · `EXPORT_FAILED` · `ASSET_MODERATION_BLOCKED` · `CONFLICT` ·
`RATE_LIMITED` · `UNSUPPORTED_MEDIA_TYPE`.

---

## 1. Route map

### 1.1 Curriculum (read)
| Method | Path | Purpose |
|---|---|---|
| GET | `/curriculum/frameworks` | Available programs (country, school year) |
| GET | `/curriculum/subjects` | Subject catalogue (i18n names, RTL flag) |
| GET | `/curriculum/tree?framework_id&year_level&subject_code` | Tree for the picker |
| GET | `/curriculum/nodes/{node_id}` | Node detail |
| GET | `/curriculum/nodes/{node_id}/children` | Lazy-load children |
| GET | `/curriculum/nodes/{node_id}/objectives` | Learning objectives |
| GET | `/curriculum/nodes/{node_id}/coverage` | Source-chunk counts → warn before generating |
| GET | `/curriculum/search?q&year_level&subject_code` | Free-text node search |

### 1.2 Custom sources (teacher-supplied grounding)
| Method | Path | Purpose |
|---|---|---|
| POST | `/sources/uploads` | `multipart/form-data` PDF/DOCX/image → parse+chunk+embed |
| POST | `/sources/text` | Pasted chapter text |
| GET | `/sources/{source_id}` | Status, chunk count, detected topics, warnings |
| DELETE | `/sources/{source_id}` | Delete + purge chunks |

### 1.3 Generation
| Method | Path | Purpose |
|---|---|---|
| POST | `/generation-jobs` | **Core entry point.** Scope + preferences → `202` job |
| GET | `/generation-jobs/{job_id}` | State, progress, counts, warnings, cost |
| GET | `/generation-jobs/{job_id}/events` | **SSE** live progress + items as they validate |
| GET | `/generation-jobs/{job_id}/pool` | The candidate pool (filter/sort) |
| GET | `/generation-jobs/{job_id}/blueprint` | Planner output (transparency) |
| POST | `/generation-jobs/{job_id}/cancel` | Cooperative cancel |
| POST | `/generation-jobs/{job_id}/extend` | Add N more candidates to an existing pool |

### 1.4 Exercises
| Method | Path | Purpose |
|---|---|---|
| GET | `/exercises` | Bank: filter by subject, year, type, difficulty, tags, objective |
| GET | `/exercises/{id}` | Current version + citations + validation verdict |
| GET | `/exercises/{id}/versions` | Version history |
| POST | `/exercises` | Teacher-authored exercise |
| PATCH | `/exercises/{id}` | Edit → creates a new version |
| POST | `/exercises/{id}/regenerate` | "Regenerate this one" (keeps slot intent) |
| POST | `/exercises/{id}/variants` | "More like this" / Form B variants |
| POST | `/exercises/{id}/feedback` | Rating / flag (wrong answer, off-syllabus…) |
| DELETE | `/exercises/{id}` | Archive |

### 1.5 Exams
| Method | Path | Purpose |
|---|---|---|
| POST | `/exams` | Create (optionally `from_job_id`) |
| GET | `/exams` · `/exams/{id}` | List / detail (full assembled paper) |
| PATCH | `/exams/{id}` | Title, header, layout options (`If-Match`) |
| DELETE | `/exams/{id}` | Archive |
| POST | `/exams/{id}/items` | Add exercise version(s) to the paper |
| PATCH | `/exams/{id}/items/{item_id}` | Marks override, inline content edit, page break |
| DELETE | `/exams/{id}/items/{item_id}` | Remove |
| PUT | `/exams/{id}/items/order` | Reorder (array of item ids) → renumbering server-side |
| POST | `/exams/{id}/sections` | Create/label sections |
| GET | `/exams/{id}/preview?format=html` | Print-faithful server-rendered preview |
| GET | `/exams/{id}/coverage` | Objective coverage + Bloom/difficulty/marks distribution |
| POST | `/exams/{id}/duplicate` | Clone for another class/term |

### 1.6 Exports
| Method | Path | Purpose |
|---|---|---|
| POST | `/exams/{id}/exports` | `{format: pdf\|docx, include_answer_key, answer_key_mode, options}` → `202` |
| GET | `/exports/{export_id}` | Status + signed download URLs |
| GET | `/exports/{export_id}/download?artifact=paper\|answer_key` | 302 → signed URL |

### 1.7 Assets
| Method | Path | Purpose |
|---|---|---|
| GET | `/assets/{asset_id}` | Metadata + status |
| POST | `/assets/{asset_id}/regenerate` | Re-run generation with a tweaked spec |
| POST | `/exercises/{id}/image` | Request/replace an illustration for an exercise |
| POST | `/assets/uploads` | Teacher supplies their own image |

### 1.8 Admin (curriculum ops)
| Method | Path | Purpose |
|---|---|---|
| POST | `/admin/books` | Upload official textbook → ingestion job |
| GET | `/admin/ingestion-jobs/{id}` | Parse/chunk/embed progress |
| GET | `/admin/ingestion-jobs/{id}/review` | Proposed tree vs page images |
| POST | `/admin/ingestion-jobs/{id}/approve` | **Review gate** → publish |
| PATCH | `/admin/nodes/{id}` | Fix a mis-parsed node |
| GET | `/admin/prompts` · POST `/admin/prompts/{name}/versions/{v}/activate` | Prompt versioning |
| GET | `/admin/metrics/quality` | Accept rate, edit rate, flags by prompt version |

### 1.9 System
`GET /health` · `GET /health/ready` (DB, Redis, MCP, providers) · `GET /version`

---

## 2. Core payloads

### 2.1 `POST /generation-jobs`

```jsonc
{
  "grounding_mode": "official_curriculum",      // | custom_source | mixed
  "framework_id": "…",
  "year_level": 4,
  "subject_code": "SCI",
  "node_ids": ["33333333-…-0004"],              // chapters the teacher ticked
  "custom_source_id": null,                     // set when uploading own chapter
  "preferences": {
    "question_count": 12,
    "pool_multiplier": 2.5,                     // pool = 30 candidates
    "difficulty_mix": { "easy": 0.2, "medium": 0.6, "hard": 0.2 },
    "type_mix": { "mcq": 0.3, "fill_blank": 0.2, "matching": 0.2, "problem_solving": 0.3 },
    "language": "fr",
    "pedagogical_focus": "comprehension and application; avoid pure recall",
    "bloom_target": { "remember": 0.2, "understand": 0.4, "apply": 0.4 },
    "allow_images": true,
    "time_limit_minutes": 45
  }
}
```

`202` →
```json
{ "job_id": "…", "state": "queued", "estimated_seconds": 35,
  "events_url": "/api/v1/generation-jobs/…/events" }
```

### 2.2 SSE event stream

```
event: state      data: {"state":"retrieving","progress":0.15}
event: state      data: {"state":"planning","progress":0.30}
event: item       data: {"exercise_id":"…","type_code":"mcq","difficulty":"easy","index":1}
event: item       data: {"exercise_id":"…","type_code":"matching","index":2}
event: warning    data: {"code":"LOW_SOURCE_COVERAGE","node_id":"…"}
event: image      data: {"exercise_id":"…","asset_id":"…","status":"ready"}
event: done       data: {"state":"ready","pool_size":31,"accepted":27,"needs_review":4}
```

### 2.3 Exercise representation

```jsonc
{
  "id": "7777…", "version": 1, "type_code": "mcq", "difficulty": "easy",
  "bloom_level": "understand", "language": "fr", "status": "accepted",
  "marks": 1, "estimated_minutes": 1.5,
  "content": {
    "instruction": "Choisis la bonne réponse.",
    "stem": "Quelle partie de la plante absorbe l'eau du sol ?",
    "options": [ {"key":"A","text":"La racine"}, {"key":"B","text":"La fleur"},
                 {"key":"C","text":"La feuille"} ],
    "media": { "asset_id": "aaaa…", "position": "above_stem", "status": "ready" }
  },
  "answer_key": { "correct": ["A"], "explanation": "Les racines absorbent l'eau…" },
  "objectives": [ {"id":"4444…","code":"SC.4.2.3","statement":"Identifier le rôle des racines…"} ],
  "citations": [ {"chunk_id":"6666…","node_id":"3333…",
                  "node_path":"Y4 / Sciences / Unité 2 / La nutrition des plantes",
                  "page":42,"book_edition":"2025"} ],
  "validation": { "verdict":"accepted", "critic_agrees":true,
                  "alignment_confidence":0.91, "ngram_overlap":6 }
}
```

### 2.4 `POST /exams/{id}/exports`

```json
{ "format": "pdf", "include_answer_key": true, "answer_key_mode": "separate_document",
  "options": { "paper":"A4", "font_size":12, "show_marks":true,
               "answer_space":"lines", "header_logo":true, "watermark":null } }
```
`202` → `{ "export_id":"…", "status":"queued" }` → `GET /exports/{id}` →
```json
{ "status":"ready", "page_count":3,
  "paper_url":"https://cdn…/paper.pdf?sig=…",
  "answer_key_url":"https://cdn…/key.pdf?sig=…", "expires_at":"2026-08-15T18:00:00Z" }
```

---

## 3. External API link wiring

**Rule:** no route handler, service or worker ever imports a vendor SDK. Everything goes through
`ai_gateway`, which is the *only* module holding provider credentials.

```
app/ai_gateway/
├── base.py         LLMProvider · ImageProvider · EmbeddingProvider · ModerationProvider · OCRProvider
├── router.py       task_kind -> provider chain (config-driven)
├── resilience.py   retry · backoff · circuit breaker · bulkhead
├── cache.py        exact-hash + semantic cache
├── accounting.py   token/cost capture -> ai_call_log
└── providers/
    ├── openai.py      chat, embeddings, DALL·E 3, moderation
    ├── anthropic.py   chat
    ├── google.py      chat, Imagen
    ├── stability.py   SDXL
    ├── replicate.py   SDXL / FLUX hosted
    └── local_vllm.py  self-hosted fallback
```

### 3.1 Provider interfaces

```python
class LLMProvider(Protocol):
    async def complete(self, *, messages: list[Msg], model: str,
                       response_schema: dict | None = None,
                       temperature: float = 0.7, max_tokens: int = 4096,
                       trace: TraceCtx) -> LLMResult: ...

class ImageProvider(Protocol):
    async def generate(self, *, prompt: str, negative_prompt: str | None,
                       size: str, n: int, style: str | None,
                       trace: TraceCtx) -> ImageResult: ...
```

### 3.2 Wiring table — where each external call happens

| Pipeline step | Module | Interface | Default binding | Env |
|---|---|---|---|---|
| Chunk classification (ingest) | `workers/ingest/classify.py` | `LLMProvider.complete` | `gpt-4o-mini` | `LLM_CLASSIFY_MODEL` |
| Objective extraction (ingest) | `workers/ingest/objectives.py` | `LLMProvider.complete` | `gpt-4o` | `LLM_EXTRACT_MODEL` |
| OCR (scanned books) | `workers/ingest/ocr.py` | `OCRProvider.extract` | Tesseract → Vision fallback | `OCR_PROVIDER` |
| Embeddings (docs + queries) | `ai_gateway/providers/*` | `EmbeddingProvider.embed` | `text-embedding-3-large` (1536d) | `EMBEDDING_MODEL` |
| **Blueprint planning** | `agent/states/plan.py` | `LLMProvider.complete` | `claude-sonnet-4` / `gpt-4o` | `LLM_PLAN_MODEL` |
| **Exercise synthesis** | `agent/states/synthesize.py` | `LLMProvider.complete` (schema mode) | `gpt-4o-mini` / `claude-haiku` | `LLM_SYNTH_MODEL` |
| **Critic / validation** | `agent/states/validate.py` | `LLMProvider.complete` | *different family* from synth | `LLM_CRITIC_MODEL` |
| **Image generation** | `workers/image/generate.py` | `ImageProvider.generate` | DALL·E 3 · SDXL · Imagen | `IMAGE_PROVIDER` |
| Image moderation | `workers/image/moderate.py` | `ModerationProvider.check` | provider moderation + own classifier | `MODERATION_PROVIDER` |
| Image verification (counts) | `workers/image/verify.py` | `LLMProvider.complete` (vision) | `gpt-4o` vision | `LLM_VISION_MODEL` |

### 3.3 Routing config (hot-reloadable)

```yaml
ai_gateway:
  routing:
    plan:       { primary: anthropic:claude-sonnet-4, fallback: [openai:gpt-4o], temperature: 0.2 }
    synthesize: { primary: openai:gpt-4o-mini, fallback: [anthropic:claude-haiku], temperature: 0.7,
                  max_concurrency: 6, structured_output: true }
    critic:     { primary: google:gemini-2.0-flash, fallback: [openai:gpt-4o-mini], temperature: 0.0 }
    classify:   { primary: openai:gpt-4o-mini, temperature: 0.0 }
    embed:      { primary: openai:text-embedding-3-large, dim: 1536 }
    image:
      count_objects:           { primary: openai:dall-e-3, size: "1024x1024" }
      vocabulary_illustration: { primary: openai:dall-e-3, size: "1024x1024" }
      labelled_diagram:        { primary: stability:sdxl, size: "1024x1024" }
      geometry_figure:         { renderer: internal_svg }     # never diffusion
      map_outline:             { renderer: asset_library }
  resilience: { timeout_s: 60, max_retries: 3, backoff: exponential_jitter,
                circuit_breaker: { error_threshold: 0.4, window_s: 60, cooldown_s: 120 } }
  budget:     { max_tokens_per_job: 250000, max_cost_usd_per_job: 0.50 }
```

### 3.4 Image call contract

```python
spec  = await agent.extract_image_spec(exercise)        # structured, never free text
prompt = render_image_prompt(spec)                       # server-owned template
key   = sha256(canonical_json(spec))                     # cache/dedupe key
if asset := await assets.find_ready(key): return asset   # zero cost on hit

img = await gateway.image.generate(prompt=prompt, negative_prompt=spec.negative_prompt,
                                   size=spec.size, n=1, trace=ctx)
await moderation.check(img)                              # blocked -> text-only fallback
if spec.purpose == "count_objects":
    await vision_verify(img, expected=spec.object_count) # mismatch -> SVG compositor
uri = await storage.put(img)                             # S3, private
await assets.mark_ready(asset_id, uri, cost=img.cost)
await sse.publish(job_id, "image", {...})                # back-fill the open UI
```

### 3.5 Webhooks (async providers)
`POST /webhooks/image/{provider}` — HMAC-signed, replay-protected (`timestamp` + nonce), idempotent
by `provider_job_id`. Used for Replicate/SDXL-style callbacks; polling fallback for providers without
webhooks.

---

## 4. Sequence: scope → export

```
1  GET  /curriculum/tree?year_level=4&subject_code=SCI      → picker
2  GET  /curriculum/nodes/{chapter}/coverage                → "42 passages, good coverage"
3  POST /generation-jobs                                    → 202 job_id
4  GET  /generation-jobs/{id}/events (SSE)                  → live items
5  GET  /generation-jobs/{id}/pool?status=accepted&sort=difficulty
6  POST /exams {from_job_id, title, class_label}            → exam_id
7  POST /exams/{id}/items {exercise_version_ids:[…]}        → items added
8  PUT  /exams/{id}/items/order                             → renumbered server-side
9  PATCH /exams/{id}/items/{item_id} {marks_override: 2}    → total_marks trigger updates
10 GET  /exams/{id}/coverage                                → objective/Bloom report
11 GET  /exams/{id}/preview?format=html                     → print-faithful preview
12 POST /exams/{id}/exports {format:"pdf", include_answer_key:true}
13 GET  /exports/{export_id}                                → signed paper + key URLs
```

---

## 5. Rate limits & quotas (non-auth)

| Scope | Limit |
|---|---|
| Generation jobs | 20/hour, 100/day per teacher |
| Concurrent jobs | 2 per teacher |
| Image generations | 60/day per teacher |
| Uploads | 20/day, 25 MB each |
| Exports | 100/day |
| Read endpoints | 600/min per IP |

`429` + `Retry-After` + `X-RateLimit-*` headers.

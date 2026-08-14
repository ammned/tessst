# 01 — System Architecture

## 0. One-paragraph summary

ExamForge is a **backend-driven, API-first** system. A thin web client only renders server state. The
core is a FastAPI application exposing REST routes; long-running AI work is pushed to worker queues.
All curriculum knowledge is reachable *only* through an **MCP server**, which the AI agent talks to
as a client — this is what makes grounding enforceable rather than aspirational. External LLM and
image providers sit behind adapter interfaces in an **AI Gateway** so no domain code ever imports a
vendor SDK. Persistence is PostgreSQL (+`pgvector`) for relational and semantic data, Redis for
queues/cache/locks, and S3-compatible object storage for source PDFs, generated images and exports.

---

## 1. Layered view

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  L0  CLIENTS            Web app (thin)   ·   Admin console   ·   Public API   │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTPS / JSON  (+ SSE for job streams)
┌───────────────────────────────▼──────────────────────────────────────────────┐
│  L1  EDGE                                                                     │
│  API Gateway → rate limit · request-id · CORS · [AUTH-LATER: JWT verify]      │
│  Injects X-Teacher-Id into every downstream request (stubbed for now)         │
└───────────────────────────────┬──────────────────────────────────────────────┘
┌───────────────────────────────▼──────────────────────────────────────────────┐
│  L2  APPLICATION  — FastAPI (stateless, horizontally scaled)                  │
│                                                                               │
│  Routers:  /curriculum  /sources  /generation-jobs  /exercises  /exams        │
│            /exports  /assets  /admin  /mcp-debug                              │
│                                                                               │
│  Services (domain layer, no vendor imports):                                  │
│   • CurriculumService     tree traversal, node resolution, objective lookup   │
│   • SourceService         upload, parse, chunk, embed, review lifecycle       │
│   • GenerationService     job creation, blueprint planning, pool assembly     │
│   • ExerciseService       CRUD, versioning, edit, clone, bank queries         │
│   • ExamService           selection, ordering, marks, numbering, validation   │
│   • ExportService         render orchestration, artefact registry             │
│   • AssetService          image spec → job → asset, dedupe, moderation state  │
└───────┬───────────────────────────────┬───────────────────────────┬───────────┘
        │                               │                           │
┌───────▼──────────────┐  ┌─────────────▼────────────┐  ┌───────────▼──────────┐
│ L3  AI ORCHESTRATION │  │ L3  MCP SERVER           │  │ L3  RENDER SERVICE   │
│  Agent Runtime       │──▶  (MCP client ↔ server)   │  │  HTML → PDF/DOCX     │
│  • plan blueprint    │  │  Resources / Tools /     │  │  • Jinja templates   │
│  • tool loop         │  │  Prompts over the        │  │  • Playwright/WeasyP │
│  • synthesize items  │  │  curriculum knowledge    │  │  • docx builder      │
│  • critic/validate   │  │  base                    │  │  • RTL font stack    │
└───────┬──────────────┘  └─────────────┬────────────┘  └───────────┬──────────┘
        │                               │                           │
┌───────▼───────────────────────────────▼───────────────────────────▼──────────┐
│  L4  AI GATEWAY   (the only place vendor SDKs exist)                          │
│  LLMProvider: OpenAI · Anthropic · Google · Mistral · local vLLM              │
│  ImageProvider: DALL·E 3 · Stable Diffusion (SDXL/Replicate) · Imagen         │
│  EmbeddingProvider · ModerationProvider · OCRProvider                         │
│  Cross-cutting: routing policy · retries · circuit breaker · token accounting │
│                 · semantic cache · prompt registry · trace logging            │
└───────┬───────────────────────────────────────────────────────────────────────┘
        │
┌───────▼───────────────────────────────────────────────────────────────────────┐
│  L5  ASYNC WORKERS  (Celery/Arq over Redis)                                    │
│  ingest.parse · ingest.embed · gen.plan · gen.synthesize · gen.validate        │
│  image.generate · export.render · maintenance.reindex · maintenance.cache_gc   │
└───────┬───────────────────────────────────────────────────────────────────────┘
        │
┌───────▼───────────────────────────────────────────────────────────────────────┐
│  L6  DATA                                                                      │
│  PostgreSQL 16 + pgvector   │  Redis   │  S3-compatible object store           │
│  relational + embeddings    │  queue,  │  raw PDFs, page images,               │
│  + full-text (tsvector)     │  cache,  │  generated images, exports            │
│                             │  locks   │                                       │
└────────────────────────────────────────────────────────────────────────────────┘
        │
┌───────▼───────────────────────────────────────────────────────────────────────┐
│  L7  OBSERVABILITY   OpenTelemetry traces · Prometheus · Loki · Langfuse-style  │
│                      LLM trace store (prompt, tools called, tokens, cost)      │
└────────────────────────────────────────────────────────────────────────────────┘
```

A rendered version of this diagram is in `diagrams/architecture.svg`.

---

## 2. Component responsibilities

### 2.1 API layer (FastAPI)
Thin. Validates payloads (Pydantic), resolves the teacher context, calls exactly one service method,
serialises the result. **No business logic, no SDK calls, no SQL.** Long operations return `202` with
a job resource and a `Location` header; progress is polled or streamed over SSE.

### 2.2 Curriculum knowledge base
The spine of the product. Built by the ingestion pipeline:

```
upload PDF/DOCX ─► virus scan ─► store raw in S3
   └─► layout parse (PyMuPDF; OCR fallback via Tesseract/Vision for scans)
        └─► structural segmentation → units / chapters / lessons
             └─► semantic chunking (400–800 tokens, heading-aware, overlap 15%)
                  └─► classify chunk: exposition | example | exercise | summary | glossary
                       └─► extract learning objectives + key vocabulary (LLM, schema-constrained)
                            └─► embed (text-embedding-3-large or multilingual-e5)
                                 └─► write curriculum_node + source_chunk + objective rows
                                      └─► ADMIN REVIEW GATE  ─► status = published
```

The review gate is non-negotiable: nothing enters retrieval as `published` without a human
curriculum admin confirming the chapter mapping. Prevents a bad parse from poisoning every exam.

### 2.3 MCP server
Full treatment in `docs/02-mcp-server.md`. Architecturally: it is a **separate process** speaking MCP
over stdio (local/dev) or streamable HTTP (prod), owning read access to the curriculum KB. The agent
runtime holds an MCP *client*. Benefits: (a) the agent's data access surface is an explicit,
auditable contract; (b) the same server can be attached to Claude Desktop / any MCP host for
curriculum Q&A with zero extra code; (c) grounding is enforced at the tool boundary — tools refuse
queries outside the session's allowed `curriculum_node` scope.

### 2.4 Agent runtime
A deterministic **state machine**, not an open-ended agent loop:

```
RESOLVE_SCOPE → RETRIEVE_CONTEXT → PLAN_BLUEPRINT → SYNTHESIZE(batched, parallel)
   → VALIDATE(critic) → REPAIR(≤1 retry per item) → EXTRACT_IMAGE_SPECS
   → PERSIST_POOL → (async) IMAGE_GENERATE → READY
```

Each state has bounded tool calls, a timeout, and a typed output schema. Free-form tool loops are
allowed *only* inside `RETRIEVE_CONTEXT` (max 8 calls). This keeps latency and cost predictable and
makes failures debuggable.

### 2.5 AI Gateway
Single choke point for every external model call.

- **Routing policy** — per task-type model selection: `plan` → strong reasoning model; `synthesize` →
  fast mid-tier, high parallelism; `critic` → different family from the synthesizer (independence
  matters for catching wrong answers); `embed` → multilingual embedder; `image` → per subject/style.
- **Resilience** — timeout, exponential backoff with jitter, ordered fallback chain, per-provider
  circuit breaker, bulkhead concurrency limits.
- **Caching** — exact-hash cache on (prompt, model, params); semantic cache for image prompts;
  `Idempotency-Key` support end-to-end.
- **Accounting** — every call writes an `ai_call_log` row (tokens, latency, cost, cache hit, job link).

### 2.6 Render service
Server-side only. Exam JSON → Jinja2 HTML (print CSS, `@page`, running headers, avoid-break rules) →
PDF via headless Chromium (Playwright) or WeasyPrint; DOCX via `python-docx` from the same
normalised layout model. Answer key rendered from the same source objects, guaranteeing consistency.

### 2.7 Workers
Idempotent, retryable, keyed by job ID. Separate queues with separate concurrency so a burst of image
jobs cannot starve exports. Dead-letter queue with replay tooling.

---

## 3. End-to-end request flow (generation)

```
Teacher                API              GenerationService      Worker            MCP           AI GW
  │  POST /generation-jobs                  │                    │               │              │
  ├────────────────────►│                   │                    │               │              │
  │                     ├─validate scope───►│                    │               │              │
  │                     │                   ├─insert job(queued) │               │              │
  │                     │                   ├─enqueue gen.plan──►│               │              │
  │  202 {job_id}  ◄────┤                   │                    │               │              │
  │                     │                   │                    ├─resources/read│(chapters)    │
  │                     │                   │                    ├─tools/call────► search_      │
  │                     │                   │                    │   curriculum  │              │
  │                     │                   │                    ├─prompts/get──►│(blueprint)   │
  │                     │                   │                    ├───────────────┼─plan────────►│
  │                     │                   │                    │◄──blueprint───┼──────────────┤
  │  GET /jobs/{id}/events (SSE)            │                    ├─synthesize xN─┼─────────────►│
  │◄─── state: synthesizing, 8/30 ──────────┤                    │◄──items───────┼──────────────┤
  │                     │                   │                    ├─validate──────┼─────────────►│
  │                     │                   │                    ├─persist pool  │              │
  │                     │                   │                    ├─enqueue image.generate xK    │
  │◄─── state: ready, pool_size: 31 ────────┤                    │               │              │
  │  GET /generation-jobs/{id}/pool         │                    │               │              │
  ├────────────────────►│  200 [exercises]  │                    │               │              │
```

---

## 4. Data flow classes

| Flow | Path | Consistency |
|---|---|---|
| Curriculum read | API → Postgres (read replica ok) | Eventually consistent, cached 1h |
| Curriculum write (ingest) | Admin → worker → Postgres + S3 | Strong; review gate before publish |
| Generation | API → Redis queue → worker → AI GW → Postgres | Job-scoped; pool written in one transaction |
| Exam edit | API → Postgres | Strong; optimistic concurrency via `version` column |
| Export | API → queue → render → S3 → signed URL | Artefact immutable once produced |
| Images | Worker → ImageProvider → S3 → `asset` row → back-fill exercise | Async; exercise usable without it |

---

## 5. Non-functional design

**Scalability.** API and workers stateless → horizontal. Postgres vertical + read replicas; pgvector
HNSW indexes per language. Image and export workers scale independently on queue depth.

**Latency.** Pool generation parallelises synthesis into batches of 4–6 items across ~6 concurrent
calls. SSE streams partial results so the teacher starts curating before the pool completes.

**Reliability.** Every external call is retried and circuit-broken. Every worker task is idempotent
(`job_id` + step key). Partial pools are valid, persisted results — a failure at item 27 does not
discard items 1–26.

**Security (non-auth).** All uploads virus-scanned and MIME-sniffed; S3 objects private with
short-lived signed URLs; prompt-injection defence on ingested/custom text (content is passed as
data-delimited blocks, never concatenated into instruction position); per-teacher quotas; PII
minimisation — no student names required anywhere.

**Cost control.** Blueprint-then-batch, semantic caching, small models for classification, image
reuse via perceptual-hash dedupe, hard per-job token ceiling with graceful degradation.

**Observability.** One `trace_id` from HTTP request through worker, MCP call and provider call.
LLM traces store prompt hash, tools invoked, retrieved chunk IDs, tokens, cost, validation verdict —
enough to reconstruct exactly why an exercise looks the way it does.

---

## 6. Deployment topology

```
                  ┌───────────── CDN (static + signed asset URLs) ─────────────┐
Internet ──► LB ──► api-svc (3+ pods, HPA on RPS/latency)
                   ├─► mcp-svc (2 pods, internal only, streamable HTTP)
                   ├─► render-svc (2 pods, Chromium, memory-heavy)
                   └─► worker pools:
                         gen-worker    (CPU light, IO heavy, HPA on queue depth)
                         image-worker  (IO heavy, separate rate-limit budget)
                         ingest-worker (CPU/RAM heavy: PDF + OCR)
                         export-worker (co-located with render-svc)

Data: managed Postgres 16 (+pgvector, PITR) · managed Redis (AOF) · S3 bucket (versioned)
Secrets: vault-injected env; no provider key ever reaches the client
Envs: dev (stdio MCP, mock providers) · staging (real providers, synthetic curriculum) · prod
```

---

## 7. Technology choices & swap notes

| Concern | Chosen | Swap-friendly alternative |
|---|---|---|
| API | FastAPI (Python 3.12) | NestJS — routes/DTOs map 1:1 |
| DB | PostgreSQL 16 + pgvector | + Qdrant/Weaviate if vector volume outgrows PG |
| Queue | Redis + Celery/Arq | SQS + Lambda, or Temporal for durable workflows |
| MCP | `mcp` Python SDK | any MCP SDK; protocol is the contract |
| PDF | Playwright (Chromium) | WeasyPrint (lighter, weaker RTL/complex CSS) |
| DOCX | python-docx | docxtpl for template-driven variants |
| Object store | S3 / MinIO | GCS / R2 |
| Tracing | OpenTelemetry + Langfuse-style LLM store | Phoenix, LangSmith |

# ExamForge — Curriculum-Grounded Exam Authoring Platform for Primary Schools

> Backend-driven AI web application that lets primary school teachers (Years 1–6, all subjects)
> generate, curate and export exams that are **strictly grounded in official Ministry of Education
> textbooks, syllabi and programs**.

**Scope note:** authentication, login and sign-up are intentionally **out of scope** in this
iteration. Every route below assumes an already-resolved `teacher_id` injected by an upstream
gateway (see `docs/04-api-blueprint.md` §0). Auth hooks are marked `[AUTH-LATER]` where they will
eventually slot in, so nothing has to be re-architected when identity lands.

---

## Deliverable map

| File | What it contains |
|---|---|
| `docs/00-ideation.md` | Product ideation: personas, jobs-to-be-done, user journeys, scope matrix, differentiators, risks, phased roadmap |
| `docs/01-architecture.md` | System architecture: layer-by-layer description, component responsibilities, request/data flow, deployment topology, non-functional design |
| `docs/02-mcp-server.md` | MCP server/client implementation structure: Resources, Tools, Prompts, transport, agent orchestration loop, session context |
| `docs/03-data-model.md` | Entity dictionary, relationship narrative, ERD, lifecycle state machines, indexing & retrieval strategy |
| `docs/04-api-blueprint.md` | Full REST route table, request/response payloads, external API "link wiring" (LLM + image providers), webhooks, error contract |
| `docs/05-ai-workflows.md` | The generation pipelines: RAG grounding, exercise synthesis, validation/critic loop, image generation, cost & caching |
| `docs/06-export.md` | Preview → render → export pipeline (PDF/DOCX), layout engine, answer-key generation, RTL/multilingual typography |
| `db/schema.sql` | Complete PostgreSQL + pgvector DDL (tables, enums, constraints, indexes, triggers, seed taxonomy) |
| `api/openapi.yaml` | OpenAPI 3.1 contract for every route in the blueprint |
| `mcp_server/` | Runnable-shaped Python MCP server skeleton: resources, tools, prompts, registry wiring |
| `diagrams/architecture.svg` | Rendered system architecture diagram |

## Verification status

Nothing here is hand-waved pseudocode — the executable artefacts were run:

| Check | Result |
|---|---|
| `db/schema.sql` applied to PostgreSQL 17 + pgvector | **PASS** — 30 tables, 3 views, 8 triggers |
| `db/smoke_test.sql` — 10 functional assertions (marks trigger, tsvector triggers, views, scope filter, constraint matrix, XOR chunk origin) | **PASS** — all 10 |
| Hybrid RRF retrieval query (vector + BM25, scope-filtered) executed on live pgvector | **PASS** — out-of-scope chapter correctly excluded |
| MCP server builds and registers | **PASS** — 15 tools, 12 resources/templates, 4 prompts |
| `mcp_server/test_scope_guard.py` — grounding guarantee | **PASS** — 9/9, fails closed |
| `api/openapi.yaml` OpenAPI 3.1 validation | **PASS** — 52 paths, 60 operations, 26 schemas |
| Enum parity: SQL ↔ Pydantic ↔ OpenAPI (`exercise_type`, `job_state`, error codes) | **PASS** — identical |
| `diagrams/architecture.svg` | **PASS** — well-formed, renders to PNG |

Two real bugs were caught and fixed by running this: an expression in a `PRIMARY KEY`
(illegal in PostgreSQL) and a missing `::text` cast on an enum-to-array comparison.

To reproduce: start PostgreSQL with `pgvector`, then
`psql -d examforge -f db/schema.sql && psql -d examforge -f db/smoke_test.sql`,
and `python -m mcp_server.test_scope_guard`.

## Assumptions taken (flag any you want changed)

1. **Curriculum authority** = Tunisian Ministry of Education primary program (6 years), but the
   curriculum tree is *data*, not code — any ministry/country loads through the same ingestion
   pipeline.
2. **Languages** = Arabic (RTL), French, English, with per-subject default language.
3. **Stack** = Python 3.12 / FastAPI + PostgreSQL 16 (`pgvector`) + Redis + S3-compatible object
   store + Celery/Arq workers. Substitutions are noted where the design is stack-agnostic.
4. **Model access** is provider-abstracted: no business logic ever imports an SDK directly.

## Reading order

`00-ideation` → `01-architecture` → `02-mcp-server` → `03-data-model` → `04-api-blueprint` →
`05-ai-workflows` → `06-export`.

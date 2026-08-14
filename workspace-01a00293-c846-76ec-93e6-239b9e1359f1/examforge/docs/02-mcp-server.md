# 02 — MCP Server / Client Implementation Structure

## 0. Why MCP here (design rationale)

The agent must never invent curriculum. The cleanest way to guarantee that is to make the curriculum
reachable **only** through a narrow, typed, auditable interface — which is exactly what the Model
Context Protocol gives us:

- **Resources** = addressable curriculum content the agent can *read* (`curriculum://` URIs).
- **Tools** = the *actions* the agent may take (search, fetch objectives, pull templates).
- **Prompts** = versioned, reusable pedagogical prompt templates, owned by curriculum experts rather
  than hardcoded in application code.

Concrete benefits: (1) grounding is enforced at the protocol boundary — a scope guard rejects any
tool call that reaches outside the session's allowed nodes; (2) every retrieval is logged as a
protocol message, so "why did this exercise say X?" is answerable; (3) the same server can be
attached to any MCP host (Claude Desktop, an IDE, an inspector) for curriculum exploration with zero
extra code; (4) generation logic and knowledge access evolve independently.

---

## 1. Topology

```
┌──────────────────────────────────────┐        ┌─────────────────────────────────┐
│  ExamForge Agent Runtime             │        │  ExamForge MCP Server           │
│  (gen-worker process)                │  MCP   │  (mcp-svc, internal only)       │
│                                      │ ◄────► │                                 │
│  MCPClientPool                       │ stdio  │  Resources  curriculum://…      │
│   ├ session(job_id) w/ scope guard   │  (dev) │  Tools      12 tools            │
│   ├ resources/list · resources/read  │  HTTP  │  Prompts    8 templates         │
│   ├ tools/list · tools/call          │ (prod) │                                 │
│   └ prompts/list · prompts/get       │        │  ↓ read-only DAL                │
└──────────────────────────────────────┘        │  Postgres (+pgvector) · S3      │
                                                └─────────────────────────────────┘
```

- **Transport:** `stdio` in dev/CI (fast, no network), **streamable HTTP** in production so the
  server scales as its own deployment and can be shared by multiple worker pods.
- **Isolation:** the MCP server holds a **read-only** DB role. It physically cannot mutate curriculum.
- **Session scoping:** each generation job opens an MCP session initialised with
  `{job_id, allowed_node_ids[], language, year_level, custom_source_id?}`. Every tool call is checked
  against this scope before touching the DB.

---

## 2. Project layout

```
mcp_server/
├── server.py               # entrypoint: builds FastMCP app, registers everything
├── config.py               # settings (DSN, transport, limits)
├── context.py              # SessionScope, scope guard, request context
├── resources/
│   ├── __init__.py         # resource registration
│   ├── curriculum.py       # curriculum://tree, /year, /subject, /chapter, /objectives
│   ├── textbook.py         # textbook://chunk/{id}, textbook://chapter/{id}/content
│   └── templates.py        # template://exercise-type/{code}
├── tools/
│   ├── __init__.py         # tool registration
│   ├── search.py           # search_curriculum, semantic_search_chunks, keyword_lookup
│   ├── objectives.py       # get_learning_objectives, get_prerequisite_objectives
│   ├── templates.py        # get_exercise_templates, get_type_constraints
│   ├── vocabulary.py       # get_chapter_vocabulary, check_vocabulary_level
│   ├── validation.py       # verify_curriculum_alignment, check_source_overlap
│   └── custom.py           # ingest_custom_source, search_custom_source
├── prompts/
│   ├── __init__.py
│   ├── blueprint.py        # exam_blueprint_planner
│   ├── synthesis.py        # per-type generation prompts
│   ├── critic.py           # validation / re-solve prompts
│   └── imagery.py          # image spec extraction prompt
├── dal/
│   ├── db.py               # asyncpg pool, read-only role
│   ├── queries.py          # parameterised SQL only
│   └── embeddings.py       # embedding client for query vectors
└── schemas.py              # pydantic models for all tool I/O
```

---

## 3. Resources

Read-only, URI-addressable, cacheable. `mimeType: application/json` unless stated.

| URI template | Returns | Notes |
|---|---|---|
| `curriculum://tree` | Full year→subject→unit index (shallow) | Cached 1h; ~40 KB |
| `curriculum://year/{year}` | Subjects + units for a year level | |
| `curriculum://subject/{subject_code}/year/{year}` | Units → chapters → objective counts | |
| `curriculum://chapter/{node_id}` | Chapter metadata, objectives, vocabulary, prerequisites | Scope-guarded |
| `curriculum://chapter/{node_id}/objectives` | Learning objectives with Bloom levels & verbs | |
| `curriculum://standards/{framework}/{code}` | Official standard text | |
| `textbook://chapter/{node_id}/content` | Ordered source chunks (exposition/example/exercise) | Scope-guarded; truncated to `max_tokens` |
| `textbook://chunk/{chunk_id}` | One chunk + page ref + citation payload | |
| `textbook://chapter/{node_id}/figures` | Figure captions/descriptions from the book | Feeds image specs |
| `template://exercise-type/{type_code}` | JSON schema + rendering rules + worked example | Static, versioned |
| `template://exercise-type/index` | All 9 types with applicability by year/subject | |
| `policy://year/{year}/constraints` | Age-appropriateness rules (sentence length, vocab, ops) | Hard constraints for synthesis |

**Scope guard:** reading `curriculum://chapter/{id}` where `id ∉ session.allowed_node_ids` returns an
MCP error `-32002 ScopeViolation`, logged as a grounding incident. This is the single most important
enforcement point in the system.

---

## 4. Tools

All inputs/outputs are JSON-schema typed (`mcp_server/schemas.py`).

### Retrieval
| Tool | Input | Output | Purpose |
|---|---|---|---|
| `search_curriculum` | `query, year?, subject?, node_ids?, top_k=8` | ranked nodes + snippets | Find where a concept lives |
| `semantic_search_chunks` | `query, node_ids[], chunk_types[]?, top_k=12, min_score=0.62` | chunks + scores + citations | Core RAG retrieval, hybrid vector+BM25 |
| `keyword_lookup` | `term, node_ids[]` | exact matches with page refs | Precise term grounding |
| `get_chapter_content` | `node_id, include=[exposition,example,exercise], max_tokens=6000` | assembled context | Bulk chapter read for planning |

### Pedagogy
| Tool | Input | Output | Purpose |
|---|---|---|---|
| `get_learning_objectives` | `node_ids[], bloom_levels[]?` | objectives w/ codes, verbs, Bloom | Blueprint targets |
| `get_prerequisite_objectives` | `node_id` | upstream objectives | Avoid untaught prerequisites |
| `get_chapter_vocabulary` | `node_ids[], language` | term list w/ first-introduced chapter | Vocabulary whitelist |
| `check_vocabulary_level` | `text, year_level, language` | `{ok, offending_terms[]}` | Age-appropriateness gate |

### Templates & constraints
| Tool | Input | Output | Purpose |
|---|---|---|---|
| `get_exercise_templates` | `type_codes[], subject, year_level` | schemas + worked examples + rules | Shape synthesis output |
| `get_type_constraints` | `type_code, year_level` | min/max options, answer format, marks band | Structural validity |

### Validation
| Tool | Input | Output | Purpose |
|---|---|---|---|
| `verify_curriculum_alignment` | `exercise_json, node_ids[]` | `{aligned, objective_ids[], confidence, reason}` | Post-hoc grounding check |
| `check_source_overlap` | `text, node_ids[]` | `{max_ngram_overlap, verbatim_risk}` | Copyright / originality guard |

### Custom sources
| Tool | Input | Output | Purpose |
|---|---|---|---|
| `ingest_custom_source` | `source_id` | `{chunk_count, detected_topics[], language}` | Register teacher upload into session scope |
| `search_custom_source` | `source_id, query, top_k` | chunks | RAG over teacher's own chapter |

**Tool contract rules**
1. Every retrieval tool returns `citations[] = [{chunk_id, node_id, page, book_edition}]`.
2. Tools never return more than `max_tokens` (default 6 000) — truncation is explicit and flagged.
3. Tools are pure reads; nothing mutates state except `ingest_custom_source` (which writes only to a
   session-scoped table).
4. Every call is logged to `mcp_call_log` with latency, result size, scope check outcome.

---

## 5. Prompts (server-owned, versioned)

| Prompt name | Arguments | Role |
|---|---|---|
| `exam_blueprint_planner` | year, subject, node_ids, question_count, difficulty_mix, type_mix, focus, language | Produces the exam blueprint: per-slot objective, type, difficulty, Bloom, marks |
| `synthesize_mcq` | blueprint_slot, context_chunks, constraints, language | One or a batch of MCQ items with distractor rationale |
| `synthesize_fill_blank` | … | Cloze items with acceptable-answer sets |
| `synthesize_matching` | … | Two balanced columns + mapping |
| `synthesize_open_ended` | … | Prompt + rubric + model answer |
| `synthesize_problem_solving` | … | Multi-step problem + worked solution + step marks |
| `critic_review_exercise` | exercise_json, context_chunks, year_level | Independent re-solve + verdict + issues[] |
| `extract_image_spec` | exercise_json, subject, year_level | Structured image spec (never free text to the image model) |

Prompts are stored as versioned rows (`prompt_template` table) and served through MCP so curriculum
experts can iterate without a code deploy. Each returns `{version, messages[]}` and every generation
records the prompt version used — essential for A/B and regression analysis.

---

## 6. Client-side integration (agent runtime)

```python
# agent/mcp_client.py  (shape, not full impl)
class CurriculumMCPClient:
    """Thin, scope-aware wrapper over an MCP session."""

    async def open(self, job: GenerationJob) -> "CurriculumMCPClient":
        self._session = await self._pool.acquire()          # stdio or HTTP session
        await self._session.initialize()
        await self._session.call_tool("__set_scope", {      # server-side guard init
            "job_id": str(job.id),
            "allowed_node_ids": [str(n) for n in job.node_ids],
            "language": job.language,
            "year_level": job.year_level,
            "custom_source_id": str(job.custom_source_id) if job.custom_source_id else None,
        })
        return self

    async def retrieve_context(self, plan_queries: list[str]) -> RetrievedContext:
        chunks, citations = [], []
        for q in plan_queries[:MAX_RETRIEVAL_CALLS]:        # bounded: 8
            res = await self._session.call_tool("semantic_search_chunks", {
                "query": q, "node_ids": self._scope.node_ids, "top_k": 12,
            })
            chunks.extend(res.chunks); citations.extend(res.citations)
        return RetrievedContext.dedupe(chunks, citations, token_budget=12_000)
```

**Connection pooling:** one long-lived MCP session per worker process, re-scoped per job (cheaper
than per-job process spawn). Sessions are health-checked and recycled every N jobs.

**Failure policy:** MCP unavailable ⇒ generation job fails fast with `MCP_UNAVAILABLE`. There is
deliberately **no ungrounded fallback path** — degrading to "just ask the LLM" would silently break
the product's core promise.

---

## 7. Agent orchestration loop

```
STATE MACHINE (agent/orchestrator.py)

RESOLVE_SCOPE
  ├ validate node_ids exist & are published        [DB]
  ├ if custom_source_id → tools/call ingest_custom_source
  └ open MCP session with scope

RETRIEVE_CONTEXT                                   [≤8 tool calls, ≤20s]
  ├ resources/read curriculum://chapter/{id} for each node
  ├ tools/call get_learning_objectives
  ├ tools/call get_chapter_vocabulary
  └ tools/call semantic_search_chunks × plan queries

PLAN_BLUEPRINT                                     [1 LLM call, strong model]
  ├ prompts/get exam_blueprint_planner
  └ → Blueprint{slots:[{slot_no, objective_id, type, difficulty, bloom, marks, needs_image}]}
      (slots = question_count × pool_multiplier, default ×2.5)

SYNTHESIZE                                         [batched, ≤6 concurrent, mid-tier model]
  ├ group slots by type → prompts/get synthesize_{type}
  ├ tools/call get_exercise_templates + get_type_constraints
  └ → ExerciseDraft[] with citations

VALIDATE                                           [1 critic call per item, different model family]
  ├ structural: JSON schema, option counts, single correct answer
  ├ prompts/get critic_review_exercise → independent re-solve
  ├ tools/call verify_curriculum_alignment
  ├ tools/call check_vocabulary_level
  ├ tools/call check_source_overlap  (verbatim/copyright guard)
  └ semantic dedupe within pool (cosine > 0.92 ⇒ drop)

REPAIR                                             [≤1 retry per failed item]
  └ feed issues[] back into synthesis; still failing ⇒ status=rejected (kept for analytics)

EXTRACT_IMAGE_SPECS
  └ prompts/get extract_image_spec for slots where needs_image

PERSIST_POOL          single transaction → exercise + exercise_version + citations
IMAGE_GENERATE        async, non-blocking; back-fills asset_id
READY                 SSE event; teacher can curate
```

**Guardrails:** total tool calls per job ≤ 40; total tokens ≤ configurable ceiling (default 250k);
wall-clock ≤ 180 s. Exceeding any ⇒ finalise with whatever passed validation and flag `partial`.

---

## 8. Observability of the MCP layer

Every MCP interaction writes `mcp_call_log`: `job_id, method, tool_name, args_hash, scope_ok,
latency_ms, result_bytes, citation_ids[], error`. Combined with `ai_call_log`, this reconstructs the
complete provenance of any exercise — which chunks were retrieved, which prompt version ran, what the
critic said. That audit trail is what lets a coordinator or inspector trust the output.

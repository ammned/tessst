# 03 — Data Model

Executable DDL: `db/schema.sql` (verified against PostgreSQL 17 + pgvector).
Functional proof: `db/smoke_test.sql` (10 assertions, all passing).

## 1. Design decisions that shape the schema

1. **Exercises are first-class, not blobs inside exams.** An exam is an *ordered selection* of
   `exercise_version` rows. This is what makes a reusable bank, remixing and Form-A/Form-B possible.
2. **Versions are immutable.** Editing creates `exercise_version` v+1. An exported exam therefore
   references the exact text it was printed with, forever — a later edit cannot retro-change a paper
   already given to pupils.
3. **Grounding is stored, not implied.** `exercise_citation` records which textbook chunks produced
   each item, and `exercise_objective` which official objectives it assesses. This is the audit trail
   behind the coverage report.
4. **One chunk table, two origins.** Official book chunks and teacher-uploaded chunks share
   `source_chunk` (XOR-constrained), so retrieval code has a single path; the distinction survives via
   `grounding_mode`.
5. **Curriculum is data.** Another ministry/country = new `curriculum_framework` rows. No code changes.
6. **Auth-shaped holes, not auth.** `teacher` is a stub with no credentials; every ownership FK exists
   already so identity can be layered in without a migration of relationships.

---

## 2. Entity dictionary

### Curriculum domain
| Table | Purpose | Key relationships |
|---|---|---|
| `subject` | Subject catalogue with i18n names and RTL flag | referenced everywhere |
| `curriculum_framework` | One official program (country + school year) | → `curriculum_node` |
| `curriculum_node` | The tree: year → subject → unit → chapter → lesson | self-referencing; `materialized_path` for subtree queries |
| `node_prerequisite` | DAG of "needs this taught first" | node ↔ node |
| `learning_objective` | Official objectives with ministry codes + Bloom | → node; embedded for alignment checks |
| `vocabulary_term` | Controlled vocabulary per chapter | → node; whitelist for Y1–3 |
| `year_policy` | Hard age-appropriateness constraints per year | consumed by synthesis + validation |

### Source domain
| Table | Purpose |
|---|---|
| `source_book` | Ingested official textbook/syllabus (content-hashed to dedupe editions) |
| `custom_source` | Teacher-uploaded/pasted chapter; TTL via `expires_at` |
| `source_chunk` | Retrievable passage; `embedding vector(1536)` + `tsv` for hybrid search; XOR book/custom |
| `source_figure` | Figures/captions from the book — reference for image generation |

### Generation domain
| Table | Purpose |
|---|---|
| `generation_job` | One "make me a pool" request: scope + preferences + blueprint + accounting |
| `generation_event` | Append-only progress log; backs the SSE stream |
| `exercise_template` | Per-type JSON schema, rendering rules, worked example (data-driven types) |
| `type_constraint` | Structural bounds per (type, year, subject); `subject_code=''` is the default row |
| `prompt_template` | Versioned prompts served via MCP; one active version per name |

### Exercise domain
| Table | Purpose |
|---|---|
| `exercise` | Logical item: type, subject, year, difficulty, status, owner, embedding |
| `exercise_version` | Immutable content + answer key + marks + asset |
| `exercise_citation` | Provenance → `source_chunk` |
| `exercise_objective` | Alignment → `learning_objective` |
| `exercise_validation` | Verdicts from the deterministic and critic tracks |
| `exercise_feedback` | Teacher ratings/flags → quality metrics |

### Assembly & output
| Table | Purpose |
|---|---|
| `exam` | The paper: header, layout, language/RTL, `total_marks` (trigger-maintained) |
| `exam_section` | Optional titled parts |
| `exam_item` | Ordered slot → `exercise_version`, with per-exam marks/content override |
| `asset` | Generated/uploaded media; `spec_hash` unique-when-ready = cache & dedupe |
| `export_job` | Render request → paper + answer-key artefacts |

### Audit
| Table | Purpose |
|---|---|
| `ai_call_log` | Every provider call: tokens, latency, cost, cache hit, prompt version |
| `mcp_call_log` | Every MCP call: tool, scope check outcome, citations returned |

---

## 3. ERD

```
curriculum_framework 1─────* curriculum_node ──┐ (self FK: parent_id)
                                    │          └──* node_prerequisite
                                    ├──* learning_objective ──* exercise_objective *── exercise
                                    ├──* vocabulary_term
                                    ├──* source_chunk *── exercise_citation *── exercise_version
                                    └──* source_figure
subject 1──* curriculum_node
        1──* source_book 1──* source_chunk
teacher 1──* custom_source 1──* source_chunk
        1──* generation_job 1──* exercise 1──* exercise_version 1──* exercise_validation
        │                  └──* generation_event                 └──0..1 asset
        1──* exam 1──* exam_section
                  1──* exam_item *──1 exercise_version
                  1──* export_job
year_policy · exercise_template · type_constraint · prompt_template   (reference data)
ai_call_log · mcp_call_log                                            (audit, job-linked)
```

---

## 4. Lifecycles

**Curriculum node / chunk**
`draft → in_review → published → archived`
Only `published` is retrievable by MCP. Archiving a superseded edition keeps old citations resolvable.

**Generation job**
`queued → resolving → retrieving → planning → synthesizing → validating → imaging → ready`
with terminal `partial` (budget/failure but usable output), `failed`, `cancelled`.

**Exercise**
`draft → accepted | needs_review | rejected → archived`
`accepted` = both validation tracks passed. `needs_review` = shown but badged, never auto-selected.
`rejected` = retained for analytics only.

**Exam** `building → finalised → exported → archived`
**Asset** `pending → generating → ready | failed | moderation_blocked`
**Export** `queued → rendering → ready | failed`

---

## 5. Retrieval & indexing strategy

**Hybrid search** (implemented in `mcp_server/dal/queries.py::hybrid_search_chunks`, executed
successfully against live pgvector):

1. Scope CTE hard-filters `node_id = ANY($1)` **in SQL** — out-of-scope rows are never loaded.
2. Vector branch: HNSW cosine (`m=16, ef_construction=64`).
3. Keyword branch: `tsvector` + `websearch_to_tsquery`.
4. Fusion: Reciprocal Rank Fusion, `k=60` — robust across incomparable score scales, no tuning.
5. Threshold + token-budget truncation, with truncation flagged rather than silent.

**Index inventory**

| Index | Table | Purpose |
|---|---|---|
| `idx_chunk_vec` (HNSW) | `source_chunk` | Semantic retrieval |
| `idx_chunk_tsv` (GIN) | `source_chunk` | Keyword branch |
| `idx_chunk_type_node` (partial) | `source_chunk` | Filtered published reads |
| `idx_objective_vec` (HNSW) | `learning_objective` | Alignment verification |
| `idx_exercise_vec` (HNSW) | `exercise` | Pool dedupe + "more like this" |
| `idx_node_path` (GIN trgm) | `curriculum_node` | Subtree/prefix queries |
| `idx_exercise_bank` | `exercise` | Bank filtering |
| `idx_job_state` (partial) | `generation_job` | Worker polling |
| `idx_asset_spec_hash` (unique partial) | `asset` | Image cache/dedupe |
| `idx_mcp_scope_violation` (partial) | `mcp_call_log` | Security monitoring |

**Embedding dimension** 1536, one shared multilingual space (ar/fr/en) so a French query can retrieve
an Arabic chunk when the subject is bilingual.

---

## 6. Integrity guarantees (all verified in `db/smoke_test.sql`)

| Guarantee | Mechanism | Test |
|---|---|---|
| `exam.total_marks` always correct | `trg_exam_marks` on insert/update/delete | assertions 1–3 |
| Search vectors always populated | `trg_node_tsv`, `trg_chunk_tsv` | assertion 4 |
| Current version resolvable | `v_exercise_current` view | assertion 5 |
| Coverage report accurate | `v_exam_coverage` view | assertion 6 |
| Scope filter cannot leak other chapters | `node_id = ANY(...)` in SQL | assertions 7 |
| Type/year constraint matrix complete | seed cross-join (10 × 6 = 60 rows) | assertion 8 |
| Age-inappropriate types blocked | seeded `applicable=false` for Y1–2 | assertion 9 |
| A chunk has exactly one origin | `chk_chunk_origin` | assertion 10 |
| Exam items can't reference deleted content | `ON DELETE RESTRICT` on `exercise_version` | FK |
| Idempotent job creation | unique partial index on `(teacher_id, idempotency_key)` | index |

---

## 7. Data volume & retention

| Entity | Est. scale (1 ministry, 50k teachers) | Retention |
|---|---|---|
| `curriculum_node` | ~15k | Permanent, versioned by framework |
| `source_chunk` | ~800k (≈60 books × 6 years) | Permanent while edition active |
| `exercise` | ~30M/year | Bank kept; `rejected` purged after 90 days |
| `generation_job` | ~2M/year | Full row 1 year → aggregate after |
| `asset` | ~5M images | Dedupe by `spec_hash`; unreferenced GC after 30 days |
| `ai_call_log` | ~50M/year | 90 days detail → monthly rollups |
| `custom_source` | bursty | TTL 30 days (`expires_at`) |

Partition `ai_call_log`, `mcp_call_log` and `generation_event` monthly by `created_at`.

---

## 8. Migration notes

- Migrations via Alembic; every change additive-then-backfill-then-drop (no destructive single step).
- `pgvector` dimension changes require a new column + re-embed job; never alter in place.
- **When auth arrives:** add `school`, `role`, `membership` tables; add `school_id` to `teacher` and
  `exam`; convert `is_shared` into a proper permission join. No existing FK changes.

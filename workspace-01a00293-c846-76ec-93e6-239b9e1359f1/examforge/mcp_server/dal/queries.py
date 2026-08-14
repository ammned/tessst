"""Parameterised SQL for every MCP resource and tool.

Only the retrieval-critical queries are written out in full; the rest are declared with
their contract so the implementation is unambiguous. No string interpolation of user
input anywhere — scope filtering happens IN SQL via `= ANY($n::uuid[])`.
"""
from __future__ import annotations

from uuid import UUID

from . import db

TOKENS_PER_CHAR = 0.28  # rough multilingual estimate used for budgeting


# ---------------------------------------------------------------- scope expansion
async def expand_node_ids(node_ids: list[UUID]) -> list[UUID]:
    """Expand selected nodes to include all descendants (chapter -> lessons)."""
    sql = """
    WITH RECURSIVE sub AS (
        SELECT id FROM curriculum_node
         WHERE id = ANY($1::uuid[]) AND status = 'published'
        UNION ALL
        SELECT c.id FROM curriculum_node c
          JOIN sub s ON c.parent_id = s.id
         WHERE c.status = 'published'
    )
    SELECT id FROM sub;
    """
    return [r["id"] for r in await db.fetch(sql, node_ids)]


# --------------------------------------------------------------- hybrid retrieval
async def hybrid_search_chunks(
    *, query: str, query_vector: list[float], node_ids: list[UUID],
    chunk_types: list[str] | None, top_k: int, min_score: float, token_budget: int,
):
    """Vector + BM25 fused with Reciprocal Rank Fusion, hard-scoped to node_ids.

    RRF (k=60) is used instead of a weighted score blend because the two scales are not
    comparable and RRF is robust without per-corpus tuning.
    """
    sql = """
    WITH scoped AS (
        SELECT sc.id, sc.node_id, sc.chunk_type, sc.content, sc.page_number,
               sc.embedding, sc.tsv, cn.path_label, sb.edition
          FROM source_chunk sc
          JOIN curriculum_node cn ON cn.id = sc.node_id
          LEFT JOIN source_book sb ON sb.id = sc.book_id
         WHERE sc.node_id = ANY($1::uuid[])
           AND sc.status = 'published'
           AND ($2::text[] IS NULL OR sc.chunk_type::text = ANY($2::text[]))
    ),
    vec AS (
        SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> $3::vector) AS rnk,
               1 - (embedding <=> $3::vector) AS score
          FROM scoped ORDER BY embedding <=> $3::vector LIMIT $4 * 3
    ),
    kw AS (
        SELECT id, ROW_NUMBER() OVER (
                 ORDER BY ts_rank_cd(tsv, websearch_to_tsquery($5)) DESC) AS rnk
          FROM scoped WHERE tsv @@ websearch_to_tsquery($5) LIMIT $4 * 3
    ),
    fused AS (
        SELECT COALESCE(v.id, k.id) AS id,
               COALESCE(1.0/(60 + v.rnk), 0) + COALESCE(1.0/(60 + k.rnk), 0) AS rrf,
               COALESCE(v.score, 0) AS vscore
          FROM vec v FULL OUTER JOIN kw k ON k.id = v.id
    )
    SELECT s.id AS chunk_id, s.node_id, s.chunk_type, s.content AS text,
           s.page_number AS page, s.path_label AS node_path, s.edition AS book_edition,
           f.vscore AS score
      FROM fused f JOIN scoped s ON s.id = f.id
     WHERE f.vscore >= $6
     ORDER BY f.rrf DESC
     LIMIT $4;
    """
    rows = await db.fetch(
        sql, node_ids, chunk_types, query_vector, top_k, query, min_score
    )
    chunks, total, truncated = [], 0, False
    for r in rows:
        est = int(len(r["text"]) * TOKENS_PER_CHAR)
        if total + est > token_budget:
            truncated = True
            break
        chunks.append(_to_chunk(r))
        total += est
    return chunks, total, truncated


def _to_chunk(r: dict):
    from ..schemas import Citation, SourceChunk

    citation = Citation(
        chunk_id=r["chunk_id"], node_id=r["node_id"], node_path=r["node_path"],
        page=r.get("page"), book_edition=r.get("book_edition"),
    )
    return SourceChunk(
        chunk_id=r["chunk_id"], node_id=r["node_id"], chunk_type=r["chunk_type"],
        text=r["text"], score=r.get("score"), citation=citation,
    )


async def search_nodes(*, query, year, subject, node_ids, top_k):
    """Rank curriculum nodes by title/summary relevance. Returns CurriculumHit dicts."""
    sql = """
    SELECT cn.id AS node_id, cn.path_label AS node_path, cn.node_type, cn.title,
           LEFT(COALESCE(cn.summary, cn.title), 240) AS snippet,
           ts_rank_cd(cn.tsv, websearch_to_tsquery($1)) AS score
      FROM curriculum_node cn
     WHERE cn.status = 'published'
       AND ($2::int  IS NULL OR cn.year_level = $2)
       AND ($3::text IS NULL OR cn.subject_code = $3)
       AND ($4::uuid[] IS NULL OR cn.id = ANY($4::uuid[]))
       AND cn.tsv @@ websearch_to_tsquery($1)
     ORDER BY score DESC LIMIT $5;
    """
    return await db.fetch(sql, query, year, subject, node_ids, top_k)


async def keyword_lookup(term: str, node_ids: list[UUID]) -> dict:
    sql = """
    SELECT sc.id AS chunk_id, sc.node_id, sc.page_number AS page,
           ts_headline('simple', sc.content, plainto_tsquery($1)) AS excerpt
      FROM source_chunk sc
     WHERE sc.node_id = ANY($2::uuid[]) AND sc.content ILIKE '%' || $1 || '%'
     LIMIT 20;
    """
    rows = await db.fetch(sql, term, node_ids)
    return {"term": term, "found": bool(rows), "matches": rows}


async def fetch_chapter_chunks(node_id: UUID, include=None, max_tokens: int = 6000):
    """Ordered chunks for one chapter, truncated to a token budget."""
    sql = """
    SELECT sc.id AS chunk_id, sc.node_id, sc.chunk_type, sc.content AS text,
           sc.page_number AS page, cn.path_label AS node_path, sb.edition AS book_edition
      FROM source_chunk sc
      JOIN curriculum_node cn ON cn.id = sc.node_id
      LEFT JOIN source_book sb ON sb.id = sc.book_id
     WHERE sc.node_id = $1 AND sc.status = 'published'
       AND ($2::text[] IS NULL OR sc.chunk_type::text = ANY($2::text[]))
     ORDER BY sc.ordinal;
    """
    rows = await db.fetch(sql, node_id, include)
    chunks, total, truncated = [], 0, False
    for r in rows:
        est = int(len(r["text"]) * TOKENS_PER_CHAR)
        if total + est > max_tokens:
            truncated = True
            break
        chunks.append(_to_chunk(r))
        total += est
    node_path = rows[0]["node_path"] if rows else ""
    return {"node_id": node_id, "node_path": node_path, "chunks": chunks,
            "total_tokens": total, "truncated": truncated}


async def fetch_objectives(node_ids: list[UUID], bloom_levels=None):
    sql = """
    SELECT id AS objective_id, node_id, code, statement, bloom_level,
           action_verbs, is_terminal
      FROM learning_objective
     WHERE node_id = ANY($1::uuid[])
       AND ($2::text[] IS NULL OR bloom_level = ANY($2::text[]))
     ORDER BY code;
    """
    return await db.fetch(sql, node_ids, bloom_levels)


# ---- contracts implemented against the same schema (bodies elided for brevity) ----
async def fetch_curriculum_tree() -> dict: ...
async def fetch_year(year: int) -> dict: ...
async def fetch_subject_year(subject_code: str, year: int) -> dict: ...
async def fetch_chapter_detail(node_id: UUID) -> dict: ...
async def fetch_standard(framework: str, code: str) -> dict: ...
async def fetch_chunk(chunk_id: UUID) -> dict: ...
async def fetch_figures(node_id: UUID) -> list[dict]: ...
async def fetch_year_policy(year: int) -> dict: ...
async def fetch_template_index() -> list[dict]: ...
async def fetch_template(type_code: str) -> dict: ...
async def fetch_templates(type_codes, subject, year_level) -> list[dict]: ...
async def fetch_type_constraints(type_code: str, year_level: int) -> dict: ...
async def fetch_prerequisites(node_id: UUID) -> dict: ...
async def fetch_vocabulary(node_ids, language) -> list[dict]: ...
async def check_vocabulary(*, text, year_level, language) -> dict: ...
async def verify_alignment(exercise_json: dict, node_ids) -> dict: ...
async def check_overlap(text: str, node_ids) -> dict: ...
async def ingest_custom_source(source_id: UUID) -> dict: ...
async def search_custom_chunks(*, source_id, query_vector, top_k): ...
async def fetch_active_prompt(name: str) -> dict: ...

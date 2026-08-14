"""Retrieval tools — the agent's only path to textbook content.

Hybrid retrieval: pgvector cosine similarity fused with BM25 full-text via Reciprocal
Rank Fusion, then hard-filtered by session scope. The scope filter is applied *in SQL*
(not post-hoc) so out-of-scope content is never even loaded.
"""
from __future__ import annotations

from uuid import UUID

from mcp.server.mcpserver import MCPServer

from ..context import require_scope, current_scope
from ..dal import queries as q
from ..dal.embeddings import embed_query
from ..schemas import (
    GetChapterContentInput, GetChapterContentOutput,
    SearchCurriculumInput, SearchCurriculumOutput,
    SemanticSearchInput, SemanticSearchOutput,
)


def register(mcp: MCPServer) -> None:

    @mcp.tool()
    async def search_curriculum(params: SearchCurriculumInput) -> SearchCurriculumOutput:
        """Find WHERE a concept lives in the official program.

        Use during planning to locate the chapters that cover a topic. Returns ranked
        curriculum nodes with snippets — not full content. Filtered to the session
        scope when `node_ids` is omitted and a scope is active.
        """
        scope = current_scope()
        node_filter = params.node_ids or list(scope.effective_node_ids) or None
        if node_filter:
            require_scope(node_filter)
        rows = await q.search_nodes(
            query=params.query, year=params.year, subject=params.subject,
            node_ids=node_filter, top_k=params.top_k,
        )
        return SearchCurriculumOutput(hits=rows, truncated=len(rows) >= params.top_k)

    @mcp.tool()
    async def semantic_search_chunks(params: SemanticSearchInput) -> SemanticSearchOutput:
        """PRIMARY RAG TOOL. Retrieve textbook passages relevant to a query, restricted
        to the chapters the teacher selected.

        Every returned chunk carries a citation {chunk_id, node_id, page, edition} that
        MUST be attached to any exercise derived from it. Results below `min_score` are
        dropped rather than padded — an empty result means the program does not cover
        the query, and the exercise should not be invented.
        """
        require_scope(params.node_ids)
        vector = await embed_query(params.query)
        chunks, tokens, truncated = await q.hybrid_search_chunks(
            query=params.query,
            query_vector=vector,
            node_ids=params.node_ids,
            chunk_types=[c.value for c in (params.chunk_types or [])] or None,
            top_k=params.top_k,
            min_score=params.min_score,
            token_budget=6_000,
        )
        return SemanticSearchOutput(
            chunks=chunks,
            citations=[c.citation for c in chunks],
            total_tokens=tokens,
            truncated=truncated,
        )

    @mcp.tool()
    async def keyword_lookup(term: str, node_ids: list[UUID]) -> dict:
        """Exact-match lookup of a term inside the selected chapters.

        Use to confirm a specific word/definition/formula actually appears in the book
        before building an exercise around it.
        """
        require_scope(node_ids)
        return await q.keyword_lookup(term, node_ids)

    @mcp.tool()
    async def get_chapter_content(
        params: GetChapterContentInput,
    ) -> GetChapterContentOutput:
        """Bulk-read one chapter's content for blueprint planning.

        Prefer `semantic_search_chunks` for targeted synthesis; use this when the agent
        needs a holistic view of what the chapter actually teaches.
        """
        require_scope([params.node_id])
        result = await q.fetch_chapter_chunks(
            params.node_id,
            include=[c.value for c in params.include],
            max_tokens=params.max_tokens,
        )
        return GetChapterContentOutput(**result)

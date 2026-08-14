"""Custom (teacher-uploaded) source tools.

When a teacher uploads their own chapter, it is parsed and chunked into a
session-scoped table. Retrieval works identically, but the resulting exam is flagged
`grounding_mode = custom_source` and the coverage report explicitly states it was NOT
verified against the official program. Honest labelling protects trust in the
grounded path.
"""
from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..context import current_scope
from ..dal import queries as q
from ..dal.embeddings import embed_query
from ..schemas import (
    IngestCustomSourceInput, IngestCustomSourceOutput,
    SearchCustomSourceInput, SearchCustomSourceOutput,
)


class CustomSourceScopeError(RuntimeError):
    pass


def _assert_session_source(source_id) -> None:
    scope = current_scope()
    if scope.custom_source_id != source_id:
        raise CustomSourceScopeError(
            "Custom source is not attached to this generation session."
        )


def register(mcp: MCPServer) -> None:

    @mcp.tool()
    async def ingest_custom_source(
        params: IngestCustomSourceInput,
    ) -> IngestCustomSourceOutput:
        """Register a teacher-uploaded chapter into the current session.

        Returns detected topics and language. Warnings are surfaced to the teacher,
        e.g. 'document appears to be a scan with low OCR confidence' or 'content looks
        like Year 6 material but Year 3 was selected'.
        """
        _assert_session_source(params.source_id)
        return IngestCustomSourceOutput(**await q.ingest_custom_source(params.source_id))

    @mcp.tool()
    async def search_custom_source(
        params: SearchCustomSourceInput,
    ) -> SearchCustomSourceOutput:
        """RAG retrieval over the teacher's own uploaded chapter."""
        _assert_session_source(params.source_id)
        vector = await embed_query(params.query)
        chunks, truncated = await q.search_custom_chunks(
            source_id=params.source_id, query_vector=vector, top_k=params.top_k
        )
        return SearchCustomSourceOutput(chunks=chunks, truncated=truncated)

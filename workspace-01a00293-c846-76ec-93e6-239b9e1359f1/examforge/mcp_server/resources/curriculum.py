"""curriculum:// and textbook:// resources.

Resources are READ-ONLY, URI-addressable views over the curriculum knowledge base.
The agent uses them for bulk context; tools are for targeted queries.
"""
from __future__ import annotations

import json
from uuid import UUID

from mcp.server.mcpserver import MCPServer

from ..context import require_scope
from ..dal import queries as q


def register(mcp: MCPServer) -> None:
    # ---------------------------------------------------------------- navigation
    @mcp.resource("curriculum://tree", mime_type="application/json")
    async def curriculum_tree() -> str:
        """Shallow index of the whole official program: years -> subjects -> units.

        Cached for 1h. Use this to orient before drilling into a chapter.
        """
        return json.dumps(await q.fetch_curriculum_tree(), ensure_ascii=False)

    @mcp.resource("curriculum://year/{year}", mime_type="application/json")
    async def curriculum_year(year: str) -> str:
        """All subjects and units taught in a given primary year (1-6)."""
        return json.dumps(await q.fetch_year(int(year)), ensure_ascii=False)

    @mcp.resource(
        "curriculum://subject/{subject_code}/year/{year}", mime_type="application/json"
    )
    async def curriculum_subject(subject_code: str, year: str) -> str:
        """Units -> chapters -> objective counts for one subject in one year."""
        return json.dumps(
            await q.fetch_subject_year(subject_code, int(year)), ensure_ascii=False
        )

    # ------------------------------------------------------------------- chapter
    @mcp.resource("curriculum://chapter/{node_id}", mime_type="application/json")
    async def chapter_detail(node_id: str) -> str:
        """Chapter metadata: title, position in the program, objectives, vocabulary,
        prerequisites, estimated teaching hours. SCOPE-GUARDED."""
        nid = UUID(node_id)
        require_scope([nid])
        return json.dumps(await q.fetch_chapter_detail(nid), ensure_ascii=False)

    @mcp.resource(
        "curriculum://chapter/{node_id}/objectives", mime_type="application/json"
    )
    async def chapter_objectives(node_id: str) -> str:
        """Official learning objectives with ministry codes and Bloom levels."""
        nid = UUID(node_id)
        require_scope([nid])
        return json.dumps(await q.fetch_objectives([nid]), ensure_ascii=False)

    @mcp.resource(
        "curriculum://standards/{framework}/{code}", mime_type="application/json"
    )
    async def standard(framework: str, code: str) -> str:
        """Verbatim text of an official standard, by framework and code."""
        return json.dumps(await q.fetch_standard(framework, code), ensure_ascii=False)

    # ------------------------------------------------------------------ textbook
    @mcp.resource("textbook://chapter/{node_id}/content", mime_type="application/json")
    async def chapter_content(node_id: str) -> str:
        """Ordered textbook chunks for a chapter (exposition + examples), truncated to
        a safe token budget. Every chunk carries a citation. SCOPE-GUARDED."""
        nid = UUID(node_id)
        require_scope([nid])
        return json.dumps(
            await q.fetch_chapter_chunks(nid, max_tokens=6_000), ensure_ascii=False
        )

    @mcp.resource("textbook://chunk/{chunk_id}", mime_type="application/json")
    async def chunk(chunk_id: str) -> str:
        """A single source chunk with page reference and full citation payload."""
        row = await q.fetch_chunk(UUID(chunk_id))
        require_scope([UUID(row["node_id"])])
        return json.dumps(row, ensure_ascii=False)

    @mcp.resource("textbook://chapter/{node_id}/figures", mime_type="application/json")
    async def chapter_figures(node_id: str) -> str:
        """Figure captions and descriptions from the official book — the reference
        material for generating pedagogically consistent illustrations."""
        nid = UUID(node_id)
        require_scope([nid])
        return json.dumps(await q.fetch_figures(nid), ensure_ascii=False)

    # ---------------------------------------------------------- policy/templates
    @mcp.resource("policy://year/{year}/constraints", mime_type="application/json")
    async def year_constraints(year: str) -> str:
        """Hard age-appropriateness constraints for a year level: max sentence length,
        allowed arithmetic operations, number ranges, vocabulary tier, image density."""
        return json.dumps(await q.fetch_year_policy(int(year)), ensure_ascii=False)

    @mcp.resource("template://exercise-type/index", mime_type="application/json")
    async def template_index() -> str:
        """All supported exercise types with applicability by year and subject."""
        return json.dumps(await q.fetch_template_index(), ensure_ascii=False)

    @mcp.resource("template://exercise-type/{type_code}", mime_type="application/json")
    async def template_detail(type_code: str) -> str:
        """JSON schema, rendering rules and a worked example for one exercise type."""
        return json.dumps(await q.fetch_template(type_code), ensure_ascii=False)

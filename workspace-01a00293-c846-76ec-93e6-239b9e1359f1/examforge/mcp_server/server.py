"""ExamForge MCP server entrypoint.

Transport:
  dev  : stdio            python -m mcp_server.server
  prod : streamable HTTP  MCP_TRANSPORT=http python -m mcp_server.server

The server holds a READ-ONLY database role. It cannot mutate curriculum data — the
only write path is the session-scoped custom-source table.
"""
from __future__ import annotations

import logging
import os

from mcp.server.mcpserver import MCPServer

from .context import SessionScope, set_scope
from .dal import db, queries as q
from .prompts import registry as prompts_registry
from .resources import curriculum as curriculum_resources
from .schemas import SetScopeInput, SetScopeOutput
from .tools import custom, pedagogy, search, templates, validation

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("examforge.mcp")

mcp = MCPServer(
    name="examforge-curriculum",
    instructions=(
        "Curriculum knowledge server for ExamForge. It exposes the official Ministry "
        "of Education primary program (years 1-6, all subjects) as Resources, Tools "
        "and Prompts.\n\n"
        "RULES FOR THE AGENT:\n"
        "1. Never invent curriculum content. Every exercise must cite chunk_ids "
        "returned by semantic_search_chunks and objective_ids returned by "
        "get_learning_objectives.\n"
        "2. Stay inside the session scope. Out-of-scope reads fail with -32002.\n"
        "3. If retrieval returns nothing above threshold, report low coverage instead "
        "of generating unsupported items.\n"
        "4. Respect year-level policy constraints from policy://year/{year}/constraints."
    ),
)


# --------------------------------------------------------------- scope bootstrap
@mcp.tool(name="__set_scope")
async def set_session_scope(params: SetScopeInput) -> SetScopeOutput:
    """Initialise the session's curriculum scope. Called once per generation job
    before any other tool. Expands each selected node to include its descendants."""
    effective = await q.expand_node_ids(params.allowed_node_ids)
    scope = SessionScope(
        job_id=params.job_id,
        allowed_node_ids=set(params.allowed_node_ids),
        effective_node_ids=set(effective),
        language=params.language,
        year_level=params.year_level,
        custom_source_id=params.custom_source_id,
    )
    set_scope(scope)
    log.info(
        "scope_set job=%s nodes=%d effective=%d sig=%s",
        params.job_id, len(params.allowed_node_ids), len(effective), scope.signature,
    )
    return SetScopeOutput(
        ok=True, resolved_node_count=len(effective), scope_signature=scope.signature
    )


def build() -> MCPServer:
    curriculum_resources.register(mcp)
    search.register(mcp)
    pedagogy.register(mcp)
    templates.register(mcp)
    validation.register(mcp)
    custom.register(mcp)
    prompts_registry.register(mcp)
    return mcp


def main() -> None:
    build()
    transport = os.getenv("MCP_TRANSPORT", "stdio")
    if transport == "http":
        mcp.run(
            transport="streamable-http",
            host="0.0.0.0",                       # preview/proxy friendly
            port=int(os.getenv("MCP_PORT", "8081")),
        )
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    db.init_sync()
    main()

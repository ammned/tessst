"""Exercise template + structural constraint tools.

Templates are DATA, not prompt prose. The synthesis step receives a JSON schema and a
worked example, and must emit conforming JSON. This is what makes 10 exercise types
maintainable without 10 bespoke prompt files drifting apart.
"""
from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..dal import queries as q
from ..schemas import (
    GetTemplatesInput, GetTemplatesOutput,
    GetTypeConstraintsInput, GetTypeConstraintsOutput,
)


def register(mcp: MCPServer) -> None:

    @mcp.tool()
    async def get_exercise_templates(params: GetTemplatesInput) -> GetTemplatesOutput:
        """JSON schema + rendering rules + worked example for each requested exercise
        type, specialised for the subject and year level.

        `applicable=false` means the type is pedagogically unsuitable here (e.g.
        multi-step problem_solving in Year 1) — the planner must not allocate slots to
        it.
        """
        rows = await q.fetch_templates(
            type_codes=[t.value for t in params.type_codes],
            subject=params.subject,
            year_level=params.year_level,
        )
        return GetTemplatesOutput(templates=rows)

    @mcp.tool()
    async def get_type_constraints(
        params: GetTypeConstraintsInput,
    ) -> GetTypeConstraintsOutput:
        """Hard structural bounds for one type at one year level.

        e.g. Year 2 MCQ: 3 options max, stem <= 12 words, exactly one correct answer,
        marks 0.5-1, image recommended. Enforced mechanically at validation, so the
        model does not have to be trusted to remember them.
        """
        return GetTypeConstraintsOutput(
            **await q.fetch_type_constraints(params.type_code.value, params.year_level)
        )

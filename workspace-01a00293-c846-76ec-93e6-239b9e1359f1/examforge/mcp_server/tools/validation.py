"""Validation tools — the grounding and originality guards.

Called during the VALIDATE state, after synthesis. These are deterministic/DB-backed
checks; the LLM critic pass is separate (see prompts/critic.py). Both must pass.
"""
from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..context import require_scope
from ..dal import queries as q
from ..schemas import (
    CheckOverlapInput, CheckOverlapOutput,
    VerifyAlignmentInput, VerifyAlignmentOutput,
)


def register(mcp: MCPServer) -> None:

    @mcp.tool()
    async def verify_curriculum_alignment(
        params: VerifyAlignmentInput,
    ) -> VerifyAlignmentOutput:
        """Post-hoc grounding check: does this exercise actually test something the
        selected chapters teach?

        Embeds the exercise, compares against the chapters' objective and chunk
        embeddings, and returns the objectives it plausibly assesses. `aligned=false`
        or confidence < 0.65 sends the item to REPAIR, then to `rejected`.
        """
        require_scope(params.node_ids)
        return VerifyAlignmentOutput(
            **await q.verify_alignment(params.exercise_json, params.node_ids)
        )

    @mcp.tool()
    async def check_source_overlap(params: CheckOverlapInput) -> CheckOverlapOutput:
        """Originality / copyright guard.

        Computes the longest verbatim n-gram shared between the generated text and the
        source textbook. Policy: >12-gram overlap => verbatim_risk='high' => the item is
        rejected and regenerated. We ground on the book; we do not reproduce it.
        """
        require_scope(params.node_ids)
        return CheckOverlapOutput(
            **await q.check_overlap(params.text, params.node_ids)
        )

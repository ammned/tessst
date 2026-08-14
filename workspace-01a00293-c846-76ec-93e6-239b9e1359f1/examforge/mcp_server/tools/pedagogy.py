"""Pedagogy tools: objectives, prerequisites, vocabulary and age-appropriateness.

These are what separate "an LLM wrote some questions" from "an assessment aligned to
the official program". The blueprint planner is required to bind every slot to a real
objective ID returned by `get_learning_objectives`.
"""
from __future__ import annotations

from uuid import UUID

from mcp.server.mcpserver import MCPServer

from ..context import require_scope
from ..dal import queries as q
from ..schemas import (
    CheckVocabularyInput, CheckVocabularyOutput,
    GetObjectivesInput, GetObjectivesOutput,
    GetVocabularyInput, GetVocabularyOutput,
)


def register(mcp: MCPServer) -> None:

    @mcp.tool()
    async def get_learning_objectives(params: GetObjectivesInput) -> GetObjectivesOutput:
        """Fetch the official ministry learning objectives for the selected chapters.

        Each objective has a ministry code (e.g. 'SC.4.2.3'), a statement, a Bloom
        level and canonical action verbs. EVERY generated exercise must cite at least
        one objective_id from this list — unbound exercises are rejected at validation.
        """
        require_scope(params.node_ids)
        rows = await q.fetch_objectives(
            params.node_ids,
            bloom_levels=[b.value for b in (params.bloom_levels or [])] or None,
        )
        return GetObjectivesOutput(objectives=rows)

    @mcp.tool()
    async def get_prerequisite_objectives(node_id: UUID) -> dict:
        """Objectives from EARLIER chapters that this chapter depends on.

        Use to avoid writing a question that silently requires untaught knowledge —
        the most common cause of an "unfair" exam.
        """
        require_scope([node_id])
        return await q.fetch_prerequisites(node_id)

    @mcp.tool()
    async def get_chapter_vocabulary(params: GetVocabularyInput) -> GetVocabularyOutput:
        """The controlled vocabulary introduced by the selected chapters.

        For Years 1-3 this is effectively a WHITELIST: question stems should not use
        content words outside this list plus the cumulative prior-year vocabulary.
        """
        require_scope(params.node_ids)
        rows = await q.fetch_vocabulary(params.node_ids, params.language)
        return GetVocabularyOutput(terms=rows)

    @mcp.tool()
    async def check_vocabulary_level(
        params: CheckVocabularyInput,
    ) -> CheckVocabularyOutput:
        """Age-appropriateness gate for a piece of generated text.

        Checks vocabulary tier, sentence length and readability against the year-level
        policy. Called during VALIDATE on every stem, option and instruction.
        """
        return CheckVocabularyOutput(
            **await q.check_vocabulary(
                text=params.text,
                year_level=params.year_level,
                language=params.language,
            )
        )

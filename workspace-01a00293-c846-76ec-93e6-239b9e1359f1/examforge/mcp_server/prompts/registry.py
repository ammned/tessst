"""MCP Prompts — versioned pedagogical templates served from the database.

Prompts live in `prompt_template` rows, not in code, so curriculum experts can iterate
without a deploy. Every generation records the prompt version used, which makes A/B
testing and quality regressions traceable.
"""
from __future__ import annotations

import json

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.prompts import base

from ..dal import queries as q


async def _render(name: str, variables: dict) -> tuple[str, str]:
    """Load the active version of a prompt template and interpolate variables."""
    tpl = await q.fetch_active_prompt(name)
    body = tpl["body"]
    for key, value in variables.items():
        token = "{{" + key + "}}"
        if token in body:
            rendered = (
                json.dumps(value, ensure_ascii=False, indent=2)
                if isinstance(value, (dict, list))
                else str(value)
            )
            body = body.replace(token, rendered)
    return body, tpl["version"]


def register(mcp: MCPServer) -> None:

    @mcp.prompt()
    async def exam_blueprint_planner(
        year_level: int,
        subject: str,
        objectives_json: str,
        question_count: int,
        difficulty_mix_json: str,
        type_mix_json: str,
        pedagogical_focus: str,
        language: str,
        pool_multiplier: float = 2.5,
    ) -> list[base.Message]:
        """Plan the exam blueprint BEFORE writing any question.

        Produces one slot per candidate exercise, each bound to a real objective_id,
        an exercise type, a difficulty, a Bloom level, marks and a needs_image flag.
        Planning first is what gives the pool a coherent cognitive distribution instead
        of 30 random recall questions.
        """
        body, version = await _render("exam_blueprint_planner", {
            "year_level": year_level, "subject": subject,
            "objectives": objectives_json, "question_count": question_count,
            "difficulty_mix": difficulty_mix_json, "type_mix": type_mix_json,
            "pedagogical_focus": pedagogical_focus, "language": language,
            "slot_count": int(question_count * pool_multiplier),
        })
        return [
            base.AssistantMessage(f"[prompt_version={version}]"),
            base.UserMessage(body),
        ]

    @mcp.prompt()
    async def synthesize_exercises(
        type_code: str,
        slots_json: str,
        context_chunks_json: str,
        constraints_json: str,
        vocabulary_json: str,
        language: str,
    ) -> list[base.Message]:
        """Generate a BATCH of exercises of one type from blueprint slots.

        Context chunks are passed as delimited DATA, never as instructions
        (prompt-injection defence for ingested/teacher-uploaded text). Output must
        conform to the type's JSON schema and cite chunk_ids + objective_ids.
        """
        body, version = await _render(f"synthesize_{type_code}", {
            "slots": slots_json, "context_chunks": context_chunks_json,
            "constraints": constraints_json, "vocabulary": vocabulary_json,
            "language": language,
        })
        return [
            base.AssistantMessage(f"[prompt_version={version}]"),
            base.UserMessage(body),
        ]

    @mcp.prompt()
    async def critic_review_exercise(
        exercise_json: str,
        context_chunks_json: str,
        year_level: int,
        language: str,
    ) -> list[base.Message]:
        """Independent review pass, run on a DIFFERENT model family than synthesis.

        The critic re-solves the item from scratch before seeing the proposed answer,
        then reports: answer agreement, curriculum support, age appropriateness,
        ambiguity, distractor quality. Disagreement => needs_review, never silent ship.
        """
        body, version = await _render("critic_review_exercise", {
            "exercise": exercise_json, "context_chunks": context_chunks_json,
            "year_level": year_level, "language": language,
        })
        return [
            base.AssistantMessage(f"[prompt_version={version}]"),
            base.UserMessage(body),
        ]

    @mcp.prompt()
    async def extract_image_spec(
        exercise_json: str, subject: str, year_level: int, language: str
    ) -> list[base.Message]:
        """Turn an exercise into a STRUCTURED image spec.

        Never passes teacher or model free text straight to the image API. Emits
        {style, subject_matter, object_count, labels[], layout, palette,
        negative_prompt} which the AssetService renders into a templated provider
        prompt — deterministic, cacheable and safe.
        """
        body, version = await _render("extract_image_spec", {
            "exercise": exercise_json, "subject": subject,
            "year_level": year_level, "language": language,
        })
        return [
            base.AssistantMessage(f"[prompt_version={version}]"),
            base.UserMessage(body),
        ]

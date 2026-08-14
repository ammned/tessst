"""Typed I/O contracts for every MCP tool.

These Pydantic models are the single source of truth for the JSON schemas advertised
through `tools/list`. Keep them narrow: the agent should never receive a free-form blob.
"""
from __future__ import annotations

from enum import Enum
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, conint, confloat


# --------------------------------------------------------------------------- enums
class ExerciseType(str, Enum):
    MCQ = "mcq"
    MULTI_SELECT = "multi_select"
    TRUE_FALSE = "true_false"
    FILL_BLANK = "fill_blank"
    MATCHING = "matching"
    ORDERING = "ordering"
    SHORT_ANSWER = "short_answer"
    OPEN_ENDED = "open_ended"
    PROBLEM_SOLVING = "problem_solving"
    LABEL_DIAGRAM = "label_diagram"


class Difficulty(str, Enum):
    EASY = "easy"
    MEDIUM = "medium"
    HARD = "hard"


class BloomLevel(str, Enum):
    REMEMBER = "remember"
    UNDERSTAND = "understand"
    APPLY = "apply"
    ANALYZE = "analyze"
    EVALUATE = "evaluate"
    CREATE = "create"


class ChunkType(str, Enum):
    EXPOSITION = "exposition"
    EXAMPLE = "example"
    EXERCISE = "exercise"
    SUMMARY = "summary"
    GLOSSARY = "glossary"
    FIGURE_CAPTION = "figure_caption"


# ---------------------------------------------------------------------- primitives
class Citation(BaseModel):
    """Every retrieval result carries these. No citation -> no grounding."""
    chunk_id: UUID
    node_id: UUID
    node_path: str = Field(description="e.g. 'Y4 / Sciences / Unit 2 / Photosynthesis'")
    page: int | None = None
    book_edition: str | None = None


class SourceChunk(BaseModel):
    chunk_id: UUID
    node_id: UUID
    chunk_type: ChunkType
    text: str
    score: confloat(ge=0, le=1) | None = None
    citation: Citation


class LearningObjective(BaseModel):
    objective_id: UUID
    node_id: UUID
    code: str = Field(description="Official ministry objective code, e.g. 'SC.4.2.3'")
    statement: str
    bloom_level: BloomLevel
    action_verbs: list[str] = []
    is_terminal: bool = Field(default=False, description="Assessed at end of cycle")


class VocabularyTerm(BaseModel):
    term: str
    language: str
    definition: str | None = None
    first_introduced_node_id: UUID | None = None


# ------------------------------------------------------------------- scope control
class SetScopeInput(BaseModel):
    """Initialises the session guard. Called once per generation job."""
    job_id: UUID
    allowed_node_ids: list[UUID] = Field(min_length=0)
    language: str = "fr"
    year_level: conint(ge=1, le=6)
    custom_source_id: UUID | None = None


class SetScopeOutput(BaseModel):
    ok: bool
    resolved_node_count: int
    scope_signature: str = Field(description="Hash of the scope, logged with every call")


# ------------------------------------------------------------------- retrieval I/O
class SearchCurriculumInput(BaseModel):
    query: str
    year: conint(ge=1, le=6) | None = None
    subject: str | None = None
    node_ids: list[UUID] | None = None
    top_k: conint(ge=1, le=25) = 8


class CurriculumHit(BaseModel):
    node_id: UUID
    node_path: str
    node_type: Literal["year", "subject", "unit", "chapter", "lesson"]
    title: str
    snippet: str
    score: confloat(ge=0, le=1)


class SearchCurriculumOutput(BaseModel):
    hits: list[CurriculumHit]
    truncated: bool = False


class SemanticSearchInput(BaseModel):
    query: str
    node_ids: list[UUID] = Field(min_length=1, description="Hard scope filter")
    chunk_types: list[ChunkType] | None = None
    top_k: conint(ge=1, le=30) = 12
    min_score: confloat(ge=0, le=1) = 0.62


class SemanticSearchOutput(BaseModel):
    chunks: list[SourceChunk]
    citations: list[Citation]
    total_tokens: int
    truncated: bool = False


class GetChapterContentInput(BaseModel):
    node_id: UUID
    include: list[ChunkType] = [ChunkType.EXPOSITION, ChunkType.EXAMPLE]
    max_tokens: conint(ge=500, le=20_000) = 6_000


class GetChapterContentOutput(BaseModel):
    node_id: UUID
    node_path: str
    chunks: list[SourceChunk]
    total_tokens: int
    truncated: bool


# -------------------------------------------------------------------- pedagogy I/O
class GetObjectivesInput(BaseModel):
    node_ids: list[UUID] = Field(min_length=1)
    bloom_levels: list[BloomLevel] | None = None


class GetObjectivesOutput(BaseModel):
    objectives: list[LearningObjective]


class GetVocabularyInput(BaseModel):
    node_ids: list[UUID] = Field(min_length=1)
    language: str = "fr"


class GetVocabularyOutput(BaseModel):
    terms: list[VocabularyTerm]


class CheckVocabularyInput(BaseModel):
    text: str
    year_level: conint(ge=1, le=6)
    language: str = "fr"


class CheckVocabularyOutput(BaseModel):
    ok: bool
    offending_terms: list[str] = []
    readability_score: float | None = None
    max_sentence_length: int | None = None


# ------------------------------------------------------------------- templates I/O
class GetTemplatesInput(BaseModel):
    type_codes: list[ExerciseType] = Field(min_length=1)
    subject: str
    year_level: conint(ge=1, le=6)


class ExerciseTemplate(BaseModel):
    type_code: ExerciseType
    json_schema: dict
    rendering_rules: dict
    worked_example: dict
    applicable: bool = True
    notes: str | None = None


class GetTemplatesOutput(BaseModel):
    templates: list[ExerciseTemplate]


class GetTypeConstraintsInput(BaseModel):
    type_code: ExerciseType
    year_level: conint(ge=1, le=6)


class GetTypeConstraintsOutput(BaseModel):
    type_code: ExerciseType
    min_options: int | None = None
    max_options: int | None = None
    max_stem_words: int
    answer_format: str
    marks_min: float
    marks_max: float
    image_allowed: bool
    image_recommended: bool


# ------------------------------------------------------------------ validation I/O
class VerifyAlignmentInput(BaseModel):
    exercise_json: dict
    node_ids: list[UUID] = Field(min_length=1)


class VerifyAlignmentOutput(BaseModel):
    aligned: bool
    objective_ids: list[UUID] = []
    confidence: confloat(ge=0, le=1)
    reason: str


class CheckOverlapInput(BaseModel):
    text: str
    node_ids: list[UUID] = Field(min_length=1)


class CheckOverlapOutput(BaseModel):
    max_ngram_overlap: int = Field(description="Longest verbatim n-gram shared with source")
    verbatim_risk: Literal["none", "low", "medium", "high"]
    matched_chunk_id: UUID | None = None


# --------------------------------------------------------------- custom source I/O
class IngestCustomSourceInput(BaseModel):
    source_id: UUID


class IngestCustomSourceOutput(BaseModel):
    source_id: UUID
    chunk_count: int
    detected_topics: list[str]
    language: str
    warnings: list[str] = []


class SearchCustomSourceInput(BaseModel):
    source_id: UUID
    query: str
    top_k: conint(ge=1, le=30) = 12


class SearchCustomSourceOutput(BaseModel):
    chunks: list[SourceChunk]
    truncated: bool = False

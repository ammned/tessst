"""Query-embedding client.

Calls the same EmbeddingProvider used at ingestion time so query and document vectors
live in the same space. Cached by text hash in Redis (queries repeat heavily across
jobs on the same chapter).
"""
from __future__ import annotations

import hashlib

from ..config import settings

_MEM: dict[str, list[float]] = {}


async def embed_query(text: str) -> list[float]:
    key = hashlib.sha256(f"{settings.embedding_model}:{text}".encode()).hexdigest()
    if key in _MEM:
        return _MEM[key]
    vector = await _call_provider(text)
    _MEM[key] = vector
    return vector


async def _call_provider(text: str) -> list[float]:
    """Wired to the AI Gateway's EmbeddingProvider (see docs/04-api-blueprint.md §7)."""
    raise NotImplementedError("Bind to AI Gateway EmbeddingProvider at deploy time.")

"""MCP server settings."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    transport: str = os.getenv("MCP_TRANSPORT", "stdio")
    port: int = int(os.getenv("MCP_PORT", "8081"))
    db_dsn: str = os.getenv("MCP_DB_DSN", "postgresql://examforge_ro@localhost/examforge")
    embedding_model: str = os.getenv("EMBEDDING_MODEL", "text-embedding-3-large")
    embedding_dim: int = int(os.getenv("EMBEDDING_DIM", "1536"))
    max_tool_calls_per_session: int = int(os.getenv("MCP_MAX_TOOL_CALLS", "40"))
    default_token_budget: int = int(os.getenv("MCP_TOKEN_BUDGET", "6000"))
    cache_ttl_seconds: int = int(os.getenv("MCP_CACHE_TTL", "3600"))


settings = Settings()

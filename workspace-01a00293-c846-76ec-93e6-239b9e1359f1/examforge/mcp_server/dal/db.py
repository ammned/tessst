"""Read-only asyncpg pool for the MCP server.

The DSN points at a role granted SELECT only on curriculum tables (plus INSERT on the
session-scoped custom chunk table). Enforcing read-only at the database level means a
prompt-injection attack against the agent still cannot corrupt the curriculum.
"""
from __future__ import annotations

import os
from typing import Any

_POOL: Any = None

DSN = os.getenv(
    "MCP_DB_DSN", "postgresql://examforge_ro:***@localhost:5432/examforge"
)


async def init() -> Any:
    global _POOL
    if _POOL is None:
        import asyncpg  # imported lazily so the skeleton imports without the driver

        _POOL = await asyncpg.create_pool(
            DSN, min_size=2, max_size=10, command_timeout=15,
            server_settings={"default_transaction_read_only": "on"},
        )
    return _POOL


def init_sync() -> None:
    """Entry-point convenience; the pool is created on first use in async context."""
    return None


async def pool() -> Any:
    return await init()


async def fetch(sql: str, *args) -> list[dict]:
    p = await pool()
    async with p.acquire() as conn:
        return [dict(r) for r in await conn.fetch(sql, *args)]


async def fetchrow(sql: str, *args) -> dict | None:
    p = await pool()
    async with p.acquire() as conn:
        row = await conn.fetchrow(sql, *args)
        return dict(row) if row else None

"""Session scope + guard.

This module is the enforcement point for curriculum grounding. If a tool touches
curriculum data, it MUST pass through `require_scope()` first. A scope violation is a
protocol error, not a soft warning — that is what makes "grounded or nothing" real.
"""
from __future__ import annotations

import hashlib
import logging
from contextvars import ContextVar
from dataclasses import dataclass, field
from uuid import UUID

log = logging.getLogger("examforge.mcp.scope")

SCOPE_VIOLATION = -32002  # JSON-RPC application error code advertised to clients


class ScopeViolation(Exception):
    """Raised when a tool call reaches outside the session's allowed curriculum nodes."""

    def __init__(self, requested: list[UUID], allowed: list[UUID]) -> None:
        self.code = SCOPE_VIOLATION
        self.requested = requested
        self.allowed = allowed
        super().__init__(
            f"ScopeViolation: {len(requested)} node(s) requested outside session scope "
            f"of {len(allowed)} allowed node(s). Generation must stay within the "
            f"chapters the teacher selected."
        )


@dataclass
class SessionScope:
    job_id: UUID | None = None
    allowed_node_ids: set[UUID] = field(default_factory=set)
    #: expanded set including descendants (a chapter implies its lessons)
    effective_node_ids: set[UUID] = field(default_factory=set)
    language: str = "fr"
    year_level: int = 1
    custom_source_id: UUID | None = None
    tool_call_count: int = 0
    max_tool_calls: int = 40

    @property
    def signature(self) -> str:
        raw = "|".join(sorted(str(n) for n in self.effective_node_ids))
        return hashlib.sha256(raw.encode()).hexdigest()[:16]

    def contains(self, node_ids: list[UUID]) -> bool:
        return set(node_ids).issubset(self.effective_node_ids)


_scope: ContextVar[SessionScope] = ContextVar("mcp_scope", default=SessionScope())


def current_scope() -> SessionScope:
    return _scope.get()


def set_scope(scope: SessionScope) -> None:
    _scope.set(scope)


def require_scope(node_ids: list[UUID]) -> SessionScope:
    """Guard every curriculum read. Raises ScopeViolation when out of bounds."""
    scope = current_scope()

    scope.tool_call_count += 1
    if scope.tool_call_count > scope.max_tool_calls:
        raise RuntimeError(
            f"Tool-call budget exhausted ({scope.max_tool_calls}) for job {scope.job_id}"
        )

    if not scope.effective_node_ids:
        raise RuntimeError("Session scope not initialised — call __set_scope first.")

    if not scope.contains(node_ids):
        outside = [n for n in node_ids if n not in scope.effective_node_ids]
        log.warning(
            "scope_violation job=%s outside=%s signature=%s",
            scope.job_id, outside, scope.signature,
        )
        raise ScopeViolation(requested=outside, allowed=list(scope.effective_node_ids))

    return scope


def truncate_to_budget(chunks: list, token_budget: int, tokens_of) -> tuple[list, int, bool]:
    """Greedy truncation so a tool never blows the agent's context window."""
    kept, total = [], 0
    for c in chunks:
        t = tokens_of(c)
        if total + t > token_budget:
            return kept, total, True
        kept.append(c)
        total += t
    return kept, total, False

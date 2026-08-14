"""End-to-end test of the MCP grounding guarantee.

Proves the property the whole product rests on: a generation session scoped to
chapter A cannot read chapter B, even if the agent asks for it directly.

Run:  python -m mcp_server.test_scope_guard
"""
from __future__ import annotations

import asyncio
import sys
from uuid import UUID, uuid4

from mcp_server.context import (
    ScopeViolation, SessionScope, current_scope, require_scope, set_scope,
)

NUTRITION = UUID("33333333-0000-0000-0000-000000000004")
VOLCANO = UUID("33333333-0000-0000-0000-000000000009")
LESSON_OF_NUTRITION = UUID("33333333-0000-0000-0000-000000000005")

PASS, FAIL = "  PASS", "  FAIL"
failures = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"{PASS if ok else FAIL}  {label}{'' if ok else '  <- ' + detail}")
    if not ok:
        failures += 1


def scoped(node_ids, **kw) -> SessionScope:
    s = SessionScope(
        job_id=uuid4(),
        allowed_node_ids=set(node_ids),
        effective_node_ids=set(node_ids),
        year_level=4,
        **kw,
    )
    set_scope(s)
    return s


async def main() -> int:
    print("\n=== MCP scope guard ===")

    # 1. in-scope read is allowed
    scoped([NUTRITION])
    try:
        require_scope([NUTRITION])
        check("in-scope chapter read allowed", True)
    except ScopeViolation as e:
        check("in-scope chapter read allowed", False, str(e))

    # 2. out-of-scope read is REFUSED (the core guarantee)
    scoped([NUTRITION])
    try:
        require_scope([VOLCANO])
        check("out-of-scope chapter read refused", False, "no exception raised")
    except ScopeViolation as e:
        check("out-of-scope chapter read refused", True)
        check("violation reports the offending node",
              VOLCANO in e.requested, f"requested={e.requested}")

    # 3. mixed request (one valid + one invalid) is refused entirely — no partial leak
    scoped([NUTRITION])
    try:
        require_scope([NUTRITION, VOLCANO])
        check("mixed in/out-of-scope request refused", False, "no exception raised")
    except ScopeViolation:
        check("mixed in/out-of-scope request refused", True)

    # 4. descendants included after expansion (chapter implies its lessons)
    s = scoped([NUTRITION])
    s.effective_node_ids.add(LESSON_OF_NUTRITION)
    try:
        require_scope([LESSON_OF_NUTRITION])
        check("descendant lesson readable after expansion", True)
    except ScopeViolation as e:
        check("descendant lesson readable after expansion", False, str(e))

    # 5. uninitialised scope fails closed (never defaults to "allow all")
    set_scope(SessionScope())
    try:
        require_scope([NUTRITION])
        check("uninitialised scope fails closed", False, "read allowed with no scope")
    except RuntimeError:
        check("uninitialised scope fails closed", True)
    except ScopeViolation:
        check("uninitialised scope fails closed", True)

    # 6. tool-call budget is enforced (runaway agent protection)
    s = scoped([NUTRITION])
    s.max_tool_calls = 3
    hit = False
    for _ in range(5):
        try:
            require_scope([NUTRITION])
        except RuntimeError:
            hit = True
            break
    check("tool-call budget enforced", hit, "budget never tripped")

    # 7. scope signature is stable and order-independent (cache-key correctness)
    a = SessionScope(effective_node_ids={NUTRITION, VOLCANO})
    b = SessionScope(effective_node_ids={VOLCANO, NUTRITION})
    check("scope signature order-independent", a.signature == b.signature,
          f"{a.signature} != {b.signature}")
    c = SessionScope(effective_node_ids={NUTRITION})
    check("different scope -> different signature", a.signature != c.signature)

    print(f"\n{'ALL SCOPE TESTS PASSED' if not failures else f'{failures} FAILURE(S)'}\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

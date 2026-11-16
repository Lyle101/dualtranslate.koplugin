"""MCP elicitation helper (design 10.8).

Kept free of mcp imports: the SDK is an optional runtime dependency for
tests, and the helper only needs duck-typed attributes from the context and
the result.
"""

from __future__ import annotations

from typing import Any


async def elicit_model(ctx: Any, message: str, schema: Any) -> dict | None:
    """Ask the client for a model name through MCP elicitation.

    Returns {"model_name", "display_name"} on accept, None on decline, on a
    client without elicitation support, or on any protocol error — the caller
    then falls back to asking the agent in plain text.
    """
    elicit = getattr(ctx, "elicit", None)
    if not callable(elicit):
        return None
    try:
        result = await elicit(message=message, schema=schema)
    except Exception:  # noqa: BLE001 - unsupported clients throw many types
        return None
    if getattr(result, "action", None) != "accept":
        return None
    data = getattr(result, "data", None)
    if data is None:
        return None
    return {
        "model_name": (getattr(data, "model_name", "") or "").strip(),
        "display_name": (getattr(data, "display_name", "") or "").strip(),
    }

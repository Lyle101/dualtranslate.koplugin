"""Elicitation helper tests (no mcp SDK needed)."""

from __future__ import annotations

import asyncio

import pytest

from dualtranslate_mcp.elicit import elicit_model


class FakeSchema:
    def __init__(self, model_name: str, display_name: str = ""):
        self.model_name = model_name
        self.display_name = display_name


class AcceptCtx:
    def __init__(self, model_name: str, display_name: str = ""):
        self.seen = None
        self.model_name = model_name
        self.display_name = display_name

    async def elicit(self, message: str, schema):
        self.seen = message

        class Result:
            action = "accept"
            data = FakeSchema(self.model_name, self.display_name)

        return Result()


class DeclineCtx:
    async def elicit(self, message: str, schema):
        class Result:
            action = "decline"
            data = None

        return Result()


class BrokenCtx:
    async def elicit(self, message: str, schema):
        raise RuntimeError("client does not support elicitation")


def test_accept_returns_model():
    ctx = AcceptCtx("GPT-5", "MCP · GPT-5")
    result = asyncio.run(elicit_model(ctx, "which model?", FakeSchema))
    assert result == {"model_name": "GPT-5", "display_name": "MCP · GPT-5"}
    assert "which model?" in ctx.seen


def test_decline_and_errors_return_none():
    assert asyncio.run(elicit_model(DeclineCtx(), "m", FakeSchema)) is None
    assert asyncio.run(elicit_model(BrokenCtx(), "m", FakeSchema)) is None
    assert asyncio.run(elicit_model(object(), "m", FakeSchema)) is None


def test_blank_model_name_is_rejected_by_caller():
    ctx = AcceptCtx("   ")
    result = asyncio.run(elicit_model(ctx, "m", FakeSchema))
    assert result["model_name"] == ""

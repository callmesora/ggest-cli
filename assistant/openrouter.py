"""Minimal OpenRouter client: streaming chat completions with tool calls (OpenAI-compatible API)."""

import json
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

import httpx

API = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")  # override: tests, proxies
TIMEOUT = httpx.Timeout(connect=15, read=180, write=30, pool=15)
APP_HEADERS = {"HTTP-Referer": "https://github.com/callmesora/ggest-cli", "X-Title": "gGest Assistant"}


class OpenRouterError(Exception):
    """An error reported by OpenRouter or the model provider, with a message fit for the user."""


@dataclass
class Reply:
    """One complete model turn, assembled from the stream."""

    text: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    finish_reason: str | None = None
    usage: dict[str, Any] = field(default_factory=dict)

    def message(self) -> dict[str, Any]:
        """The assistant message to append to the conversation."""
        msg: dict[str, Any] = {"role": "assistant", "content": self.text or None}
        if self.tool_calls:
            msg["tool_calls"] = self.tool_calls
        return msg


@dataclass
class _Assembler:
    reply: Reply = field(default_factory=Reply)
    calls: dict[int, dict[str, Any]] = field(default_factory=dict)

    def add_tool_delta(self, delta: dict[str, Any]) -> None:
        empty = {"id": "", "type": "function", "function": {"name": "", "arguments": ""}}
        call = self.calls.setdefault(delta.get("index", len(self.calls)), empty)
        call["id"] = delta.get("id") or call["id"]
        fn = delta.get("function") or {}
        call["function"]["name"] += fn.get("name") or ""
        call["function"]["arguments"] += fn.get("arguments") or ""

    def add_chunk(self, chunk: dict[str, Any]) -> str:
        """Fold one stream chunk in; returns its new text (may be empty)."""
        if chunk.get("usage"):
            self.reply.usage = chunk["usage"]
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        for tool_delta in delta.get("tool_calls") or []:
            self.add_tool_delta(tool_delta)
        if choice.get("finish_reason"):
            self.reply.finish_reason = choice["finish_reason"]
        text = delta.get("content") or ""
        self.reply.text += text
        return text

    def finish(self) -> Reply:
        self.reply.tool_calls = [self.calls[i] for i in sorted(self.calls)]
        for i, call in enumerate(self.reply.tool_calls):
            call["id"] = call["id"] or f"call_{i}"
        return self.reply


def parse_sse_line(line: str) -> dict[str, Any] | None:
    """One SSE line -> its JSON payload; None for comments, blanks and [DONE]. Raises on a streamed error."""
    if not line.startswith("data:"):
        return None
    data = line[5:].strip()
    if not data or data == "[DONE]":
        return None
    payload = json.loads(data)
    if "error" in payload:
        raise OpenRouterError(error_message(payload))
    return payload


def error_message(payload: Any) -> str:
    err = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(err, dict):
        return str(err.get("message") or err)
    return str(err or payload)


def _headers(api_key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}", **APP_HEADERS}


async def _raise_for_status(response: httpx.Response) -> None:
    if response.status_code == httpx.codes.OK:
        return
    body = await response.aread()
    try:
        message = error_message(json.loads(body))
    except ValueError:
        message = body.decode(errors="replace")[:300]
    raise OpenRouterError(f"OpenRouter {response.status_code}: {message}")


async def stream_chat(
    client: httpx.AsyncClient, api_key: str, model: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]
) -> AsyncIterator[str | Reply]:
    """Yield text deltas as they arrive, then the complete Reply (text, tool calls, usage) last."""
    body = {"model": model, "messages": messages, "tools": tools, "stream": True, "usage": {"include": True}}
    assembler = _Assembler()
    async with client.stream("POST", f"{API}/chat/completions", json=body, headers=_headers(api_key)) as response:
        await _raise_for_status(response)
        async for line in response.aiter_lines():
            chunk = parse_sse_line(line)
            if chunk and (text := assembler.add_chunk(chunk)):
                yield text
    yield assembler.finish()


async def check_key(client: httpx.AsyncClient, api_key: str) -> dict[str, Any]:
    """Validate a key: OpenRouter's key info (label, usage, limit); raises OpenRouterError when rejected."""
    response = await client.get(f"{API}/key", headers=_headers(api_key))
    await _raise_for_status(response)
    return response.json().get("data", {})

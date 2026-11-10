"""Scripted OpenRouter replies for the assistant tests."""

import json
from typing import Any

import httpx


def sse(*payloads: Any) -> bytes:
    lines = [": OPENROUTER PROCESSING"]
    lines += [f"data: {json.dumps(p)}" for p in payloads]
    lines.append("data: [DONE]")
    return ("\n\n".join(lines) + "\n\n").encode()


def text_reply(text: str) -> bytes:
    chunks = [
        {"choices": [{"delta": {"content": text[i : i + 5]}, "finish_reason": None}]} for i in range(0, len(text), 5)
    ]
    return sse(*chunks, {"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"total_tokens": 42}})


def tool_reply(name: str, args: dict[str, Any], call_id: str = "call_1") -> bytes:
    raw = json.dumps(args)
    return sse(
        {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                                "function": {"name": name, "arguments": raw[:4]}}]}}]},
        {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": raw[4:]}}]}}]},
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    )  # fmt: skip


class FakeOpenRouter:
    """httpx transport that answers chat completions from a script and records the requests."""

    def __init__(self, replies: list[bytes | httpx.Response]) -> None:
        self.replies = list(replies)
        self.requests: list[dict[str, Any]] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/key"):
            if request.headers.get("authorization") == "Bearer good-key":
                return httpx.Response(200, json={"data": {"label": "test", "usage": 1.5, "limit": None}})
            return httpx.Response(401, json={"error": {"message": "User not found.", "code": 401}})
        self.requests.append(json.loads(request.content))
        reply = self.replies.pop(0)
        if isinstance(reply, httpx.Response):
            return reply
        return httpx.Response(200, content=reply, headers={"content-type": "text/event-stream"})

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self))

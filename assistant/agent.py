"""One chat turn: stream the model's answer, run the tools it asks for, loop until it answers in text.

Yields UI events (dicts) that the server sends to the browser as Server-Sent Events:
  {"type": "title", "title"}                      session got a title from the first question
  {"type": "text", "delta"}                       answer text as it streams
  {"type": "tool_start", "id", "name", "args"}    a tool call begins
  {"type": "tool_end", "id", "ok", "summary"}     it finished
  {"type": "done", "usage"} | {"type": "error", "message"}
"""

import asyncio
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any

import httpx

from bi import dates, db

from . import openrouter, prompts, store, tools

MAX_STEPS = 12  # model calls per turn (each may request several tools)
FULL_RESULT_TURNS = 2  # tool results of the last N questions stay in full; older ones are replaced by a stub
OMITTED = "[earlier tool result omitted to save context; call the tool again if it is needed]"
TITLE_CHARS = 60
STOPPED = " [stopped]"
NOT_RUN = "[not run: the user stopped the answer]"


@dataclass
class Turn:
    session_id: str
    project: dict[str, Any]
    model: str
    api_key: str
    client: httpx.AsyncClient


def title_from(text: str) -> str:
    first = " ".join(text.split())
    return first if len(first) <= TITLE_CHARS else first[: TITLE_CHARS - 1].rstrip() + "…"


def _answered_ids(history: list[dict[str, Any]]) -> set[str]:
    return {m["tool_call_id"] for m in history if m["role"] == "tool"}


def _unanswered(message: dict[str, Any], answered: set[str]) -> list[dict[str, Any]]:
    """Stub results for tool calls that never ran (the user stopped): the API rejects calls without a result."""
    calls = message.get("tool_calls") or []
    return [{"role": "tool", "tool_call_id": c["id"], "name": c["function"]["name"], "content": NOT_RUN}
            for c in calls if c["id"] not in answered]  # fmt: skip


def model_messages(history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Stored messages -> what the model gets: OpenAI fields only; old tool results shortened."""
    user_positions = [i for i, m in enumerate(history) if m["role"] == "user"]
    keep_from = user_positions[-FULL_RESULT_TURNS] if len(user_positions) >= FULL_RESULT_TURNS else 0
    answered = _answered_ids(history)
    out = []
    for i, m in enumerate(history):
        msg = {k: m[k] for k in ("role", "content", "tool_calls", "tool_call_id", "name") if k in m}
        if m["role"] == "tool" and i < keep_from:
            msg["content"] = OMITTED
        out += [msg, *_unanswered(m, answered)]
    return out


def data_date(db_path: str) -> str:
    """The database's data date (last sales document), or a note when the database cannot be read."""
    try:
        with tools.DB_LOCK:  # same lock as tool calls: bi.db holds one current database
            db.set_db(db_path)
            return str(dates.date_words()["today"])
    except Exception as e:  # noqa: BLE001 - the chat still works and the model is told why
        return f"unknown ({e})"


async def _stream_reply(turn: Turn, convo: list[dict[str, Any]], partial: list[str]) -> AsyncIterator[Any]:
    """Text events while the model writes; the Reply last. `partial` collects text in case the user stops."""
    stream = openrouter.stream_chat(turn.client, turn.api_key, turn.model, convo, tools.specs())
    async for item in stream:
        if isinstance(item, str):
            partial.append(item)
            yield {"type": "text", "delta": item}
        else:
            yield item


async def _run_tools(turn: Turn, reply: openrouter.Reply) -> AsyncIterator[dict[str, Any]]:
    for call in reply.tool_calls:
        fn = call["function"]
        yield {"type": "tool_start", "id": call["id"], "name": fn["name"], "args": fn["arguments"]}
        result = await asyncio.to_thread(tools.execute, fn["name"], fn["arguments"], turn.project["db_path"])
        message = {"role": "tool", "tool_call_id": call["id"], "name": fn["name"], "content": result.content}
        store.add_message(turn.session_id, message, {"summary": result.summary, "ok": result.ok})
        yield {"type": "tool_end", "id": call["id"], "ok": result.ok, "summary": result.summary,
               "preview": tools.preview(result.content)}  # fmt: skip


async def _steps(turn: Turn, system: str, partial: list[str]) -> AsyncIterator[dict[str, Any]]:
    for _ in range(MAX_STEPS):
        convo = [{"role": "system", "content": system}, *model_messages(store.messages(turn.session_id))]
        reply = None
        async for item in _stream_reply(turn, convo, partial):
            if isinstance(item, openrouter.Reply):
                reply = item
            else:
                yield item
        assert reply is not None  # noqa: S101 - stream_chat always ends with the Reply
        store.add_message(turn.session_id, reply.message(), {"model": turn.model, "usage": reply.usage})
        partial.clear()
        if not reply.tool_calls:
            yield {"type": "done", "usage": reply.usage}
            return
        async for event in _run_tools(turn, reply):
            yield event
    yield {"type": "error", "message": f"stopped after {MAX_STEPS} model calls without a final answer"}


async def run_turn(turn: Turn, user_text: str) -> AsyncIterator[dict[str, Any]]:
    """Store the question, then stream the answer (with tool calls) as UI events."""
    session = store.get_session(turn.session_id)
    store.add_message(turn.session_id, {"role": "user", "content": user_text})
    if session["title"] == store.UNTITLED:
        title = title_from(user_text)
        store.update_session(turn.session_id, title=title)
        yield {"type": "title", "title": title}
    system = prompts.system_prompt(turn.project, await asyncio.to_thread(data_date, turn.project["db_path"]))
    partial: list[str] = []
    try:
        async for event in _steps(turn, system, partial):
            yield event
    except openrouter.OpenRouterError as e:
        yield {"type": "error", "message": str(e)}
    except httpx.HTTPError as e:
        yield {"type": "error", "message": f"could not reach OpenRouter: {e}"}
    finally:  # the user pressed stop (or the stream broke): keep what was already written
        if partial:
            store.add_message(turn.session_id, {"role": "assistant", "content": "".join(partial) + STOPPED})
        store.touch_session(turn.session_id)

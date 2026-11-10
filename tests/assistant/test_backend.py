"""Storage, the OpenRouter client, the tool bridge and the agent loop."""

import asyncio
import json
from pathlib import Path

import httpx
import pytest
from assistant_fakes import text_reply, tool_reply

from assistant import agent, models, openrouter, prompts, store, tools

pytestmark = pytest.mark.usefixtures("app_db")


def run(coro):
    return asyncio.run(coro)


async def collect(gen) -> list:
    return [x async for x in gen]


# --- store ---------------------------------------------------------------------------------------------


def test_settings_roundtrip() -> None:
    assert store.get_setting("api_key") is None
    store.set_setting("api_key", "k1")
    store.set_setting("api_key", "k2")
    assert store.get_setting("api_key") == "k2"
    store.set_setting("api_key", None)
    assert store.get_setting("api_key", "default") == "default"


def test_projects_sessions_messages(gdb: Path) -> None:
    p = store.create_project("Shop", str(gdb), "notes")
    assert store.list_projects()[0]["name"] == "Shop"
    assert store.update_project(p["id"], name="Shop 2", instructions=None)["name"] == "Shop 2"
    s = store.create_session(p["id"], "m1")
    assert s["title"] == store.UNTITLED
    store.add_message(s["id"], {"role": "user", "content": "hi"})
    call = {"id": "c1", "type": "function", "function": {"name": "kpis", "arguments": "{}"}}
    store.add_message(s["id"], {"role": "assistant", "content": None, "tool_calls": [call]}, {"model": "m1"})
    store.add_message(s["id"], {"role": "tool", "tool_call_id": "c1", "name": "kpis", "content": "{}"}, {"ok": True})
    msgs = store.messages(s["id"])
    assert [m["role"] for m in msgs] == ["user", "assistant", "tool"]
    assert msgs[1]["tool_calls"][0]["id"] == "c1"
    assert msgs[1]["meta"] == {"model": "m1"}
    assert msgs[2]["tool_call_id"] == "c1"
    assert store.update_session(s["id"], title="  ", model="m2")["title"] == store.UNTITLED
    store.touch_session(s["id"])
    assert store.list_sessions(p["id"])[0]["model"] == "m2"
    store.delete_project(p["id"])  # cascades
    assert store.list_projects() == []
    with pytest.raises(KeyError):
        store.get_session(s["id"])
    with pytest.raises(KeyError):
        store.create_session("missing")


def test_delete_session_and_default_project(gdb: Path) -> None:
    from bi import db  # noqa: PLC0415

    db.set_db(gdb)
    store.ensure_default_project()
    store.ensure_default_project()
    projects = store.list_projects()
    assert len(projects) == 1
    s = store.create_session(projects[0]["id"])
    store.delete_session(s["id"])
    assert store.list_sessions(projects[0]["id"]) == []


def test_store_path_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GGEST_APP_DB")
    assert store.path().name == "assistant.sqlite"


# --- models and prompt ---------------------------------------------------------------------------------


def test_models() -> None:
    assert models.as_list()[0]["id"] == models.DEFAULT_MODEL
    assert models.label(models.DEFAULT_MODEL).startswith("Claude")
    assert models.label("x/y") == "x/y"


def test_system_prompt() -> None:
    text = prompts.system_prompt({"name": "Shop", "instructions": " Series W is the web shop. "}, "2026-03-01")
    assert "business assistant of Shop" in text
    assert "2026-03-01" in text
    assert '<ui-element type="TYPE">' in text
    assert text.endswith("Series W is the web shop.")
    assert "Notes for this company" not in prompts.system_prompt({"name": "S", "instructions": ""}, "x")


# --- openrouter ----------------------------------------------------------------------------------------


@pytest.mark.parametrize("line", ["", ": comment", "data: [DONE]", "event: x", "data:   "])
def test_sse_lines_without_payload(line: str) -> None:
    assert openrouter.parse_sse_line(line) is None


def test_sse_error_line() -> None:
    with pytest.raises(openrouter.OpenRouterError, match="rate limited"):
        openrouter.parse_sse_line('data: {"error": {"message": "rate limited"}}')
    assert openrouter.error_message({"error": "plain"}) == "plain"
    assert openrouter.error_message("raw") == "raw"


def test_stream_text_and_tool_calls(fake_router) -> None:
    fake = fake_router([text_reply("Hello there"), tool_reply("kpis", {"start": "2025-01-01"})])

    async def go():
        async with fake.client() as client:
            first = await collect(openrouter.stream_chat(client, "k", "m", [], []))
            second = await collect(openrouter.stream_chat(client, "k", "m", [], []))
        return first, second

    first, second = run(go())
    assert "".join(x for x in first if isinstance(x, str)) == "Hello there"
    reply = first[-1]
    assert reply.finish_reason == "stop"
    assert reply.usage == {"total_tokens": 42}
    assert reply.message() == {"role": "assistant", "content": "Hello there"}
    call = second[-1].tool_calls[0]
    assert call["id"] == "call_1"
    assert json.loads(call["function"]["arguments"]) == {"start": "2025-01-01"}
    assert second[-1].message()["content"] is None
    assert fake.requests[0]["stream"] is True


def test_stream_http_error_and_key_check(fake_router) -> None:
    fake = fake_router([httpx.Response(402, json={"error": {"message": "Insufficient credits"}}),
                        httpx.Response(500, content=b"oops")])  # fmt: skip

    async def go():
        async with fake.client() as client:
            with pytest.raises(openrouter.OpenRouterError, match="402: Insufficient credits"):
                await collect(openrouter.stream_chat(client, "k", "m", [], []))
            with pytest.raises(openrouter.OpenRouterError, match="500: oops"):
                await collect(openrouter.stream_chat(client, "k", "m", [], []))
            info = await openrouter.check_key(client, "good-key")
            with pytest.raises(openrouter.OpenRouterError, match="User not found"):
                await openrouter.check_key(client, "bad")
        return info

    assert run(go())["label"] == "test"


def test_tool_call_without_id_gets_one() -> None:
    a = openrouter._Assembler()
    a.add_chunk({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"name": "kpis"}}]}}]})
    assert a.finish().tool_calls[0]["id"] == "call_0"


# --- tools bridge --------------------------------------------------------------------------------------


def test_specs_cover_every_tool() -> None:
    specs = tools.specs()
    assert len(specs) == 23
    kpis = next(s for s in specs if s["function"]["name"] == "kpis")
    assert "start" in kpis["function"]["parameters"]["properties"]


def test_execute(gdb: Path) -> None:
    ok = tools.execute("top_products", '{"limit": 2}', str(gdb))
    assert ok.ok
    assert ok.summary == "2 rows"
    assert json.loads(ok.content)["columns"][0] == "item_code"
    assert tools.execute("kpis", "", str(gdb)).summary == "done"
    assert not tools.execute("nope", "{}", str(gdb)).ok
    bad_json = tools.execute("kpis", "{not json", str(gdb))
    assert not bad_json.ok
    assert not tools.execute("kpis", "[1]", str(gdb)).ok
    assert not tools.execute("kpis", '{"colour": 1}', str(gdb)).ok  # unknown argument
    refused = tools.execute("query", '{"sql": "SELECT * FROM utilizadores"}', str(gdb))
    assert "password" in refused.content
    sql_error = tools.execute("query", '{"sql": "SELECT nope FROM items"}', str(gdb))
    assert not sql_error.ok


@pytest.mark.parametrize(
    ("out", "summary"),
    [({"rows": [1, 2], "truncated": True}, "2 rows (more available)"), ([1, 2, 3], "3 items"), ("abc", "3 characters"),
     ({"error": "no match"}, "no match"), ({"a": 1}, "done")],
)  # fmt: skip
def test_summarize(out, summary: str) -> None:
    assert tools.summarize(out) == summary


def test_to_text_cuts_long_results(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(tools, "MAX_RESULT_CHARS", 10)
    assert tools.to_text("x" * 50).startswith("x" * 10 + "\n[cut at 10")
    assert tools.to_text({"a": 1}) == '{"a":1}'


def test_preview() -> None:
    table = json.dumps({"columns": ["a"], "rows": [[i] for i in range(20)]})
    assert tools.preview(table) == {"columns": ["a"], "rows": [[i] for i in range(8)], "row_count": 20}
    assert tools.preview("plain text") == {"text": "plain text"}
    assert tools.preview('{"a": 1}') == {"text": '{"a": 1}'}


# --- agent ---------------------------------------------------------------------------------------------


def test_title_from() -> None:
    assert agent.title_from("  How   are\nsales? ") == "How are sales?"
    long = agent.title_from("word " * 30)
    assert len(long) <= agent.TITLE_CHARS
    assert long.endswith("…")


def _call(cid: str) -> dict:
    return {"id": cid, "type": "function", "function": {"name": "kpis", "arguments": "{}"}}


def test_model_messages_trims_old_results_and_closes_open_calls() -> None:
    history = [
        {"role": "user", "content": "q1", "meta": {}},
        {"role": "assistant", "content": None, "tool_calls": [_call("a")], "meta": {}},
        {"role": "tool", "tool_call_id": "a", "name": "kpis", "content": "BIG", "meta": {}},
        {"role": "assistant", "content": "answer 1", "meta": {}},
        {"role": "user", "content": "q2", "meta": {}},
        {"role": "assistant", "content": None, "tool_calls": [_call("b"), _call("c")], "meta": {}},
        {"role": "tool", "tool_call_id": "b", "name": "kpis", "content": "KEEP", "meta": {}},
        {"role": "user", "content": "q3", "meta": {}},
    ]
    out = agent.model_messages(history)
    assert all("meta" not in m for m in out)
    assert out[2]["content"] == agent.OMITTED
    assert any(m.get("content") == "KEEP" for m in out)
    stub = next(m for m in out if m.get("tool_call_id") == "c")
    assert stub["content"] == agent.NOT_RUN
    assert out.index(stub) == 6  # right after the assistant message that asked for it


def test_model_messages_short_history_keeps_everything() -> None:
    history = [{"role": "user", "content": "q", "meta": {}},
               {"role": "tool", "tool_call_id": "x", "name": "kpis", "content": "R", "meta": {}}]  # fmt: skip
    assert agent.model_messages(history)[1]["content"] == "R"


def test_data_date(gdb: Path, tmp_path: Path) -> None:
    assert agent.data_date(str(gdb)) == "2026-03-01"
    assert agent.data_date(str(tmp_path / "missing.sqlite")).startswith("unknown")


def _turn(project: dict, client: httpx.AsyncClient) -> agent.Turn:
    session = store.create_session(project["id"])
    return agent.Turn(session["id"], project, "test/model", "k", client)


def test_run_turn_with_a_tool_call(gdb: Path, fake_router) -> None:
    project = store.create_project("Shop", str(gdb))
    fake = fake_router([tool_reply("kpis", {"start": "year_start"}), text_reply("Sales are **€1.1k**.")])

    async def go():
        async with fake.client() as client:
            turn = _turn(project, client)
            return turn, await collect(agent.run_turn(turn, "How are sales this year?"))

    turn, events = run(go())
    kinds = [e["type"] for e in events]
    assert kinds[0] == "title"
    assert "tool_start" in kinds
    assert kinds[-1] == "done"
    end = next(e for e in events if e["type"] == "tool_end")
    assert end["ok"]
    assert "net_sales" in end["preview"]["text"]
    assert "".join(e["delta"] for e in events if e["type"] == "text") == "Sales are **€1.1k**."
    roles = [m["role"] for m in store.messages(turn.session_id)]
    assert roles == ["user", "assistant", "tool", "assistant"]
    tool_msg = store.messages(turn.session_id)[2]
    assert json.loads(tool_msg["content"])["net_sales"] == 1050.0  # date word resolved to 2026-01-01
    second_request = fake.requests[1]["messages"]
    assert second_request[0]["role"] == "system"
    assert "2026-03-01" in second_request[0]["content"]
    assert store.get_session(turn.session_id)["title"] == "How are sales this year?"


def test_run_turn_reports_errors(gdb: Path, fake_router) -> None:
    project = store.create_project("Shop", str(gdb))
    fake = fake_router([httpx.Response(401, json={"error": {"message": "No auth"}})])

    async def go():
        async with fake.client() as client:
            return await collect(agent.run_turn(_turn(project, client), "hi"))

    events = run(go())
    assert events[-1] == {"type": "error", "message": "OpenRouter 401: No auth"}


def test_run_turn_network_error(gdb: Path) -> None:
    project = store.create_project("Shop", str(gdb))

    def boom(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(boom)) as client:
            return await collect(agent.run_turn(_turn(project, client), "hi"))

    assert run(go())[-1]["message"].startswith("could not reach OpenRouter")


def test_run_turn_step_limit(gdb: Path, fake_router, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent, "MAX_STEPS", 2)
    project = store.create_project("Shop", str(gdb))
    fake = fake_router([tool_reply("kpis", {}, "c1"), tool_reply("kpis", {}, "c2")])

    async def go():
        async with fake.client() as client:
            return await collect(agent.run_turn(_turn(project, client), "loop"))

    assert run(go())[-1]["type"] == "error"


def test_stopping_keeps_the_partial_answer(gdb: Path, fake_router) -> None:
    project = store.create_project("Shop", str(gdb))
    fake = fake_router([text_reply("Partial answer that goes on")])

    async def go():
        async with fake.client() as client:
            turn = _turn(project, client)
            gen = agent.run_turn(turn, "hi")
            async for event in gen:
                if event["type"] == "text":
                    break
            await gen.aclose()  # the browser closed the stream
            return turn

    turn = run(go())
    last = store.messages(turn.session_id)[-1]
    assert last["role"] == "assistant"
    assert last["content"].endswith(agent.STOPPED)

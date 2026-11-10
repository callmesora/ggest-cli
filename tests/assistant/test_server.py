"""The web app's JSON API, its local-only guard and the streamed chat endpoint."""

import json
from pathlib import Path
from typing import ClassVar

import httpx
import pytest
from assistant_fakes import FakeOpenRouter, text_reply, tool_reply
from starlette.testclient import TestClient

from assistant import server, store

pytestmark = pytest.mark.usefixtures("app_db")
LOCAL = "http://127.0.0.1:8765"


@pytest.fixture
def router(monkeypatch: pytest.MonkeyPatch) -> FakeOpenRouter:
    fake = FakeOpenRouter([])
    real = httpx.AsyncClient
    monkeypatch.setattr(server.httpx, "AsyncClient", lambda **kw: real(transport=httpx.MockTransport(fake), **kw))
    return fake


@pytest.fixture
def client(router: FakeOpenRouter) -> TestClient:
    with TestClient(server.create_app(), base_url=LOCAL) as c:
        yield c


def events(response: httpx.Response) -> list[dict]:
    return [json.loads(line[5:]) for line in response.text.splitlines() if line.startswith("data:")]


def test_index_and_static(client: TestClient) -> None:
    assert "gGest Assistant" in client.get("/").text
    assert client.get("/static/js/app.js").status_code == 200


def test_state_and_settings(client: TestClient) -> None:
    state = client.get("/api/state").json()
    assert state["settings"] == {"has_key": False, "key_hint": None, "model": state["models"][0]["id"]}
    saved = client.put("/api/settings", json={"api_key": " sk-or-v1-abcdefghijklmnop1234 ", "model": "x/y"}).json()
    assert saved == {"has_key": True, "key_hint": "sk-or-v1…1234", "model": "x/y"}
    assert "abcdefgh" not in json.dumps(client.get("/api/state").json())  # the key never goes back to the browser
    assert client.put("/api/settings", json={"api_key": "short"}).json()["key_hint"] == "set"
    assert client.put("/api/settings", json={"api_key": ""}).json()["has_key"] is False


def test_key_check(client: TestClient) -> None:
    assert client.post("/api/settings/test", json={}).status_code == 400
    assert client.post("/api/settings/test", json={"api_key": "good-key"}).json()["ok"] is True
    bad = client.post("/api/settings/test", json={"api_key": "nope"}).json()
    assert bad == {"ok": False, "message": "OpenRouter 401: User not found."}
    store.set_setting("api_key", "good-key")
    assert client.post("/api/settings/test", json={"api_key": ""}).json()["label"] == "test"


def test_projects(client: TestClient, gdb: Path, tmp_path: Path) -> None:
    bad = client.post("/api/projects", json={"name": "X", "db_path": str(tmp_path / "missing.sqlite")})
    assert bad.status_code == 400
    assert "no file" in bad.json()["error"]
    not_ggest = tmp_path / "other.sqlite"
    not_ggest.write_bytes(b"")
    assert "not a gGest database" in client.post("/api/projects", json={"db_path": str(not_ggest)}).json()["error"]
    created = client.post("/api/projects", json={"name": " ", "db_path": str(gdb)})
    assert created.status_code == 201
    project = created.json()
    assert project["name"] == "New project"
    patched = client.patch(f"/api/projects/{project['id']}", json={"name": "Shop", "db_path": str(gdb)}).json()
    assert patched["name"] == "Shop"
    assert client.delete(f"/api/projects/{project['id']}").status_code == 204
    assert client.post(f"/api/projects/{project['id']}/sessions", json={}).status_code == 404


def test_sessions_and_chat(client: TestClient, router: FakeOpenRouter, gdb: Path) -> None:
    project = client.post("/api/projects", json={"name": "Shop", "db_path": str(gdb)}).json()
    session = client.post(f"/api/projects/{project['id']}/sessions", json={"model": "a/b"}).json()
    assert client.post(f"/api/sessions/{session['id']}/chat", json={"content": "hi"}).json()["error"].startswith("add")
    store.set_setting("api_key", "k")
    assert client.post(f"/api/sessions/{session['id']}/chat", json={"content": "  "}).status_code == 400
    router.replies += [
        tool_reply("top_products", {"limit": 2}),
        text_reply('Done <ui-element type="kpis">{}</ui-element>'),
    ]
    response = client.post(f"/api/sessions/{session['id']}/chat", json={"content": "Best products?"})
    assert response.headers["content-type"].startswith("text/event-stream")
    got = events(response)
    assert got[0]["type"] == "title"
    assert got[-1]["type"] == "done"
    assert router.requests[0]["model"] == "a/b"
    detail = client.get(f"/api/sessions/{session['id']}").json()
    assert detail["title"] == "Best products?"
    roles = [m["role"] for m in detail["messages"]]
    assert roles == ["user", "assistant", "tool", "assistant"]
    tool_msg = detail["messages"][2]
    assert "content" not in tool_msg
    assert tool_msg["preview"]["columns"][0] == "item_code"
    assert tool_msg["summary"] == "2 rows"
    assert detail["messages"][1]["model"] == "a/b"
    renamed = client.patch(f"/api/sessions/{session['id']}", json={"title": "Products", "model": "c/d"}).json()
    assert (renamed["title"], renamed["model"]) == ("Products", "c/d")
    sessions = client.get("/api/state").json()["projects"][0]["sessions"]
    assert [s["id"] for s in sessions] == [session["id"]]
    assert client.delete(f"/api/sessions/{session['id']}").status_code == 204
    assert client.get(f"/api/sessions/{session['id']}").status_code == 404


def test_bad_bodies(client: TestClient) -> None:
    assert client.put("/api/settings", content=b"not json").status_code == 400
    assert client.put("/api/settings", json=[1, 2]).status_code == 400


def test_local_only(router: FakeOpenRouter) -> None:
    app = server.create_app()
    with TestClient(app, base_url="http://evil.example") as remote:
        assert remote.get("/api/state").status_code == 403  # DNS rebinding: foreign Host header
    with TestClient(app, base_url=LOCAL) as local:
        cross = local.put("/api/settings", json={"model": "x"}, headers={"Origin": "http://evil.example"})
        assert cross.status_code == 403
        same = local.put("/api/settings", json={"model": "x"}, headers={"Origin": LOCAL})
        assert same.status_code == 200


def test_key_hint_and_ui_message() -> None:
    assert server.key_hint(None) is None
    assert server.key_hint("sk-or-v1-0123456789abcdef") == "sk-or-v1…cdef"
    msg = server.ui_message({"role": "assistant", "content": "x", "meta": {}})
    assert msg == {"role": "assistant", "content": "x"}


class FakeTimer:
    opened: ClassVar[list] = []

    def __init__(self, _delay: float, _fn: object, args: list) -> None:
        self.args = args

    def start(self) -> None:
        FakeTimer.opened.append(self.args)


def test_main_starts_uvicorn(monkeypatch: pytest.MonkeyPatch) -> None:
    from click.testing import CliRunner  # noqa: PLC0415

    seen = {}
    monkeypatch.setattr(server.uvicorn, "run", lambda _app, **kw: seen.update(kw))
    opened = FakeTimer.opened
    opened.clear()
    monkeypatch.setattr(server.threading, "Timer", FakeTimer)
    result = CliRunner().invoke(server.main, ["--port", "9999"])
    assert result.exit_code == 0
    assert seen == {"host": "127.0.0.1", "port": 9999, "log_level": "warning"}
    assert opened == [["http://127.0.0.1:9999"]]
    CliRunner().invoke(server.main, ["--no-browser"])
    assert len(opened) == 1

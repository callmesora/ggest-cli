"""Local web app for the chat assistant: `uv run ggest-app` serves the UI and a small JSON API on localhost.

The OpenRouter key and the chats stay on this computer (store.py); the browser never receives the key back.
"""

import json
import sqlite3
import threading
import webbrowser
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import click
import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response, StreamingResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from . import agent, models, openrouter, store, tools

STATIC = Path(__file__).resolve().parent / "static"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "[::1]"}
Handler = Callable[[Request], Awaitable[Response]]


# --- helpers -------------------------------------------------------------------------------------------


def key_hint(key: str | None) -> str | None:
    return f"{key[:8]}…{key[-4:]}" if key and len(key) > 16 else ("set" if key else None)  # noqa: PLR2004


def settings_view() -> dict[str, Any]:
    key = store.get_setting("api_key")
    return {"has_key": bool(key), "key_hint": key_hint(key),
            "model": store.get_setting("model", models.DEFAULT_MODEL)}  # fmt: skip


def check_database(db_path: str) -> str:
    """Reject a project database that is missing or not a built gGest database; returns the resolved path."""
    path = Path(db_path).expanduser()
    if not path.is_file():
        raise ValueError(f"no file at {path}")
    try:
        con = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)
        try:
            con.execute("SELECT 1 FROM sales_docs LIMIT 1")
        finally:
            con.close()
    except sqlite3.Error as e:
        raise ValueError(f"{path} is not a gGest database built by ggest-cli ({e})") from e
    return str(path.resolve())


def ui_message(m: dict[str, Any]) -> dict[str, Any]:
    """A stored message as the chat shows it: tool results reduced to a summary and a short preview."""
    out = {k: m[k] for k in ("role", "content", "tool_calls", "tool_call_id", "name") if k in m}
    if m["role"] == "tool":
        out["preview"] = tools.preview(m["content"] or "")
        del out["content"]
        out["summary"], out["ok"] = m["meta"].get("summary", ""), m["meta"].get("ok", True)
    if m["meta"].get("model"):
        out["model"] = m["meta"]["model"]
    return out


async def body(request: Request) -> dict[str, Any]:
    try:
        data = await request.json()
    except ValueError as e:
        raise ValueError("request body must be JSON") from e
    if not isinstance(data, dict):
        raise ValueError("request body must be a JSON object")  # noqa: TRY004 - shown to the user as 400
    return data


def sse(event: dict[str, Any]) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


# --- settings ------------------------------------------------------------------------------------------


async def get_state(_: Request) -> Response:
    store.ensure_default_project()
    projects = [{**p, "sessions": store.list_sessions(p["id"])} for p in store.list_projects()]
    return JSONResponse({"settings": settings_view(), "models": models.as_list(), "projects": projects})


async def put_settings(request: Request) -> Response:
    data = await body(request)
    if "api_key" in data:
        key = (data["api_key"] or "").strip()
        store.set_setting("api_key", key or None)
    if data.get("model"):
        store.set_setting("model", str(data["model"]).strip())
    return JSONResponse(settings_view())


async def test_key(request: Request) -> Response:
    data = await body(request)
    key = (data.get("api_key") or "").strip() or store.get_setting("api_key")
    if not key:
        raise ValueError("enter an OpenRouter API key first")
    try:
        info = await openrouter.check_key(request.app.state.http, key)
    except openrouter.OpenRouterError as e:
        return JSONResponse({"ok": False, "message": str(e)})
    return JSONResponse({"ok": True, "label": info.get("label"), "usage": info.get("usage"),
                         "limit": info.get("limit")})  # fmt: skip


# --- projects and sessions -----------------------------------------------------------------------------


async def create_project(request: Request) -> Response:
    data = await body(request)
    name = (data.get("name") or "").strip() or "New project"
    project = store.create_project(name, check_database(data.get("db_path") or ""), data.get("instructions") or "")
    return JSONResponse({**project, "sessions": []}, status_code=201)


async def update_project(request: Request) -> Response:
    data = await body(request)
    if data.get("db_path"):
        data["db_path"] = check_database(data["db_path"])
    project = store.update_project(request.path_params["id"], **{k: data.get(k) for k in ("name", "db_path",
                                                                                         "instructions")})  # fmt: skip
    return JSONResponse(project)


async def delete_project(request: Request) -> Response:
    store.delete_project(request.path_params["id"])
    return Response(status_code=204)


async def create_session(request: Request) -> Response:
    data = await body(request)
    return JSONResponse(store.create_session(request.path_params["id"], data.get("model")), status_code=201)


async def get_session(request: Request) -> Response:
    session = store.get_session(request.path_params["id"])
    messages = [ui_message(m) for m in store.messages(session["id"])]
    return JSONResponse({**session, "messages": messages})


async def update_session(request: Request) -> Response:
    data = await body(request)
    return JSONResponse(store.update_session(request.path_params["id"], data.get("title"), data.get("model")))


async def delete_session(request: Request) -> Response:
    store.delete_session(request.path_params["id"])
    return Response(status_code=204)


async def chat(request: Request) -> Response:
    """Stream one turn as Server-Sent Events; closing the connection stops it."""
    data = await body(request)
    text = (data.get("content") or "").strip()
    if not text:
        raise ValueError("empty message")
    session = store.get_session(request.path_params["id"])
    key = store.get_setting("api_key")
    if not key:
        raise ValueError("add your OpenRouter API key in Settings first")
    model = session["model"] or store.get_setting("model", models.DEFAULT_MODEL) or models.DEFAULT_MODEL
    turn = agent.Turn(session["id"], store.get_project(session["project_id"]), model, key, request.app.state.http)

    async def events() -> AsyncIterator[str]:
        async for event in agent.run_turn(turn, text):
            yield sse(event)

    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


async def index(_: Request) -> Response:
    return FileResponse(STATIC / "index.html")


# --- app -----------------------------------------------------------------------------------------------


class LocalOnly(BaseHTTPMiddleware):
    """Only this computer's browser: the Host must be local (no DNS rebinding) and requests that change something
    must come from the app's own page (no cross-site form posts)."""

    async def dispatch(self, request: Request, call_next: Handler) -> Response:
        host = request.headers.get("host", "").rsplit(":", 1)[0]
        if host not in LOCAL_HOSTS:
            return JSONResponse({"error": "local access only"}, status_code=403)
        origin = request.headers.get("origin")
        if request.method != "GET" and origin and origin.split("://", 1)[-1] != request.headers.get("host"):
            return JSONResponse({"error": "cross-site request refused"}, status_code=403)
        return await call_next(request)


async def bad_request(_: Request, exc: Exception) -> Response:
    return JSONResponse({"error": str(exc)}, status_code=400)


async def not_found(_: Request, exc: Exception) -> Response:
    return JSONResponse({"error": str(exc).strip("'\"")}, status_code=404)


@asynccontextmanager
async def lifespan(app: Starlette) -> AsyncIterator[None]:
    async with httpx.AsyncClient(timeout=openrouter.TIMEOUT) as client:
        app.state.http = client
        yield


def create_app() -> Starlette:
    routes = [
        Route("/", index),
        Route("/api/state", get_state),
        Route("/api/settings", put_settings, methods=["PUT"]),
        Route("/api/settings/test", test_key, methods=["POST"]),
        Route("/api/projects", create_project, methods=["POST"]),
        Route("/api/projects/{id}", update_project, methods=["PATCH"]),
        Route("/api/projects/{id}", delete_project, methods=["DELETE"]),
        Route("/api/projects/{id}/sessions", create_session, methods=["POST"]),
        Route("/api/sessions/{id}", get_session),
        Route("/api/sessions/{id}", update_session, methods=["PATCH"]),
        Route("/api/sessions/{id}", delete_session, methods=["DELETE"]),
        Route("/api/sessions/{id}/chat", chat, methods=["POST"]),
        Mount("/static", StaticFiles(directory=STATIC), name="static"),
    ]
    return Starlette(routes=routes, middleware=[Middleware(LocalOnly)], lifespan=lifespan,
                     exception_handlers={ValueError: bad_request, KeyError: not_found})  # fmt: skip


@click.command()
@click.option("--port", default=8765, show_default=True, help="port on this computer")
@click.option("--host", default="127.0.0.1", show_default=True, help="keep it local: the API key lives here")
@click.option("--no-browser", is_flag=True, help="do not open the browser")
def main(port: int, host: str, *, no_browser: bool) -> None:
    """Start the gGest Assistant and open it in the browser."""
    url = f"http://{'127.0.0.1' if host in ('0.0.0.0', '::') else host}:{port}"  # noqa: S104
    if not no_browser:
        threading.Timer(1.0, webbrowser.open, args=[url]).start()
    click.echo(f"gGest Assistant on {url}  (Ctrl+C to stop)")
    uvicorn.run(create_app(), host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()

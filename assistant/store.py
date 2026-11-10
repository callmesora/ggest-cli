"""Local storage for the assistant app: settings, projects (one per gGest database), chat sessions and messages.

One SQLite file: env GGEST_APP_DB, else <project>/data/assistant.sqlite (git-ignored with the rest of data/).
Messages are stored in the OpenAI chat format (role, content, tool_calls, tool_call_id) so a session can be sent
back to the model as is.
"""

import json
import os
import sqlite3
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from bi import db as bidb

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, db_path TEXT NOT NULL,
  instructions TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id)
  ON DELETE CASCADE, title TEXT NOT NULL, model TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL
  REFERENCES sessions(id) ON DELETE CASCADE, role TEXT NOT NULL, content TEXT, tool_calls TEXT,
  tool_call_id TEXT, name TEXT, meta TEXT, created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS ix_messages_session ON messages(session_id, id);
CREATE INDEX IF NOT EXISTS ix_sessions_project ON sessions(project_id, updated_at);
"""
UNTITLED = "New chat"


def path() -> Path:
    env = os.environ.get("GGEST_APP_DB")
    return Path(env) if env else bidb.PROJECT / "data" / "assistant.sqlite"


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(p, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    try:
        con.executescript(SCHEMA)
        yield con
        con.commit()
    finally:
        con.close()


def _new_id() -> str:
    return uuid.uuid4().hex[:12]


# --- settings ------------------------------------------------------------------------------------------


def get_setting(key: str, default: str | None = None) -> str | None:
    with connect() as con:
        row = con.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(key: str, value: str | None) -> None:
    with connect() as con:
        if value is None:
            con.execute("DELETE FROM settings WHERE key = ?", (key,))
        else:
            con.execute("INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        (key, value))  # fmt: skip


# --- projects ------------------------------------------------------------------------------------------


def list_projects() -> list[dict[str, Any]]:
    with connect() as con:
        return [dict(r) for r in con.execute("SELECT * FROM projects ORDER BY created_at")]


def get_project(project_id: str) -> dict[str, Any]:
    with connect() as con:
        row = con.execute("SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()
    if not row:
        raise KeyError(f"no project {project_id}")
    return dict(row)


def create_project(name: str, db_path: str, instructions: str = "") -> dict[str, Any]:
    project = {"id": _new_id(), "name": name, "db_path": db_path, "instructions": instructions,
               "created_at": time.time()}  # fmt: skip
    with connect() as con:
        con.execute("INSERT INTO projects VALUES (:id, :name, :db_path, :instructions, :created_at)", project)
    return project


def update_project(project_id: str, **fields: str) -> dict[str, Any]:
    allowed = {k: v for k, v in fields.items() if k in ("name", "db_path", "instructions") and v is not None}
    if allowed:
        sets = ", ".join(f"{k} = :{k}" for k in allowed)
        with connect() as con:
            con.execute(f"UPDATE projects SET {sets} WHERE id = :id", {**allowed, "id": project_id})
    return get_project(project_id)


def delete_project(project_id: str) -> None:
    with connect() as con:
        con.execute("DELETE FROM projects WHERE id = ?", (project_id,))


def ensure_default_project() -> None:
    """First start: a project for the default database, when it exists."""
    if not list_projects() and bidb.db_path().exists():
        create_project("My business", str(bidb.db_path()))


# --- sessions ------------------------------------------------------------------------------------------


def list_sessions(project_id: str) -> list[dict[str, Any]]:
    with connect() as con:
        rows = con.execute("SELECT * FROM sessions WHERE project_id = ? ORDER BY updated_at DESC", (project_id,))
        return [dict(r) for r in rows]


def get_session(session_id: str) -> dict[str, Any]:
    with connect() as con:
        row = con.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
    if not row:
        raise KeyError(f"no session {session_id}")
    return dict(row)


def create_session(project_id: str, model: str | None = None) -> dict[str, Any]:
    get_project(project_id)
    now = time.time()
    session = {"id": _new_id(), "project_id": project_id, "title": UNTITLED, "model": model, "created_at": now,
               "updated_at": now}  # fmt: skip
    with connect() as con:
        con.execute("INSERT INTO sessions VALUES (:id, :project_id, :title, :model, :created_at, :updated_at)", session)
    return session


def update_session(session_id: str, title: str | None = None, model: str | None = None) -> dict[str, Any]:
    with connect() as con:
        if title is not None:
            con.execute("UPDATE sessions SET title = ? WHERE id = ?", (title.strip() or UNTITLED, session_id))
        if model is not None:
            con.execute("UPDATE sessions SET model = ? WHERE id = ?", (model, session_id))
    return get_session(session_id)


def touch_session(session_id: str) -> None:
    with connect() as con:
        con.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (time.time(), session_id))


def delete_session(session_id: str) -> None:
    with connect() as con:
        con.execute("DELETE FROM sessions WHERE id = ?", (session_id,))


# --- messages ------------------------------------------------------------------------------------------


def add_message(session_id: str, message: dict[str, Any], meta: dict[str, Any] | None = None) -> None:
    """Store one chat message (OpenAI format); `meta` holds UI-only data such as a tool result summary."""
    tool_calls = message.get("tool_calls")
    with connect() as con:
        con.execute(
            "INSERT INTO messages (session_id, role, content, tool_calls, tool_call_id, name, meta, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (session_id, message["role"], message.get("content"), json.dumps(tool_calls) if tool_calls else None,
             message.get("tool_call_id"), message.get("name"), json.dumps(meta) if meta else None, time.time()),
        )  # fmt: skip


def messages(session_id: str) -> list[dict[str, Any]]:
    """The session's messages in order: OpenAI fields plus `meta` (UI data) and `created_at`."""
    with connect() as con:
        rows = con.execute("SELECT * FROM messages WHERE session_id = ? ORDER BY id", (session_id,)).fetchall()
    out = []
    for r in rows:
        msg: dict[str, Any] = {"role": r["role"], "content": r["content"], "created_at": r["created_at"]}
        if r["tool_calls"]:
            msg["tool_calls"] = json.loads(r["tool_calls"])
        if r["tool_call_id"]:
            msg["tool_call_id"] = r["tool_call_id"]
        if r["name"]:
            msg["name"] = r["name"]
        msg["meta"] = json.loads(r["meta"]) if r["meta"] else {}
        out.append(msg)
    return out

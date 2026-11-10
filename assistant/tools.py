"""The gGest business tools as LLM function tools: the same registry, schemas and compact output as the MCP server."""

import json
import sqlite3
import threading
from dataclasses import dataclass
from functools import cache
from typing import Any

from bi import db, render
from bi.mcp_server import as_mcp_tool
from bi.metrics import TOOLS

MAX_RESULT_CHARS = 30_000  # one tool result never floods the context; the tools page with offset instead
DB_LOCK = threading.Lock()  # bi.db holds one current database: one tool call at a time


@dataclass(frozen=True)
class ToolResult:
    content: str  # what the model reads (JSON or text)
    summary: str  # what the UI shows on the tool card
    ok: bool


@cache
def specs() -> list[dict[str, Any]]:
    """OpenAI/OpenRouter `tools` list for every registry tool."""
    return [
        {"type": "function",
         "function": {"name": t.name, "description": t.description, "parameters": as_mcp_tool(t).parameters}}
        for t in TOOLS.values()
    ]  # fmt: skip


def summarize(out: Any) -> str:
    """Short status for the UI: rows returned, or the size of a text answer."""
    if isinstance(out, dict) and isinstance(out.get("rows"), list):
        more = " (more available)" if out.get("truncated") else ""
        return f"{len(out['rows'])} rows{more}"
    if isinstance(out, list):
        return f"{len(out)} items"
    if isinstance(out, str):
        return f"{len(out):,} characters"
    if isinstance(out, dict) and "error" in out:
        return str(out["error"])
    return "done"


def to_text(out: Any) -> str:
    text = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False, default=str, separators=(",", ":"))
    if len(text) > MAX_RESULT_CHARS:
        cut = text[:MAX_RESULT_CHARS]
        return f"{cut}\n[cut at {MAX_RESULT_CHARS:,} characters: ask for fewer rows, a summary, or the next page]"
    return text


PREVIEW_ROWS = 8
PREVIEW_CHARS = 1500


def preview(content: str) -> dict[str, Any]:
    """What the UI shows of a result: the first rows of a table, or the start of the text."""
    try:
        data = json.loads(content)
    except ValueError:
        data = None
    if isinstance(data, dict) and isinstance(data.get("columns"), list) and isinstance(data.get("rows"), list):
        return {"columns": data["columns"], "rows": data["rows"][:PREVIEW_ROWS], "row_count": len(data["rows"])}
    return {"text": content[:PREVIEW_CHARS]}


def parse_args(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    args = json.loads(raw)
    if not isinstance(args, dict):
        raise TypeError("tool arguments must be a JSON object")
    return args


def execute(name: str, raw_args: str | None, db_path: str) -> ToolResult:
    """Run one tool on the project's database; errors come back as a result the model can read and correct."""
    tool = TOOLS.get(name)
    if not tool:
        return ToolResult(f"error: unknown tool {name!r}", f"unknown tool {name}", ok=False)
    try:
        args = parse_args(raw_args)
        with DB_LOCK:
            db.set_db(db_path)
            out = render.compact(tool.call(**args))
    except (ValueError, TypeError, sqlite3.Error, FileNotFoundError) as e:
        return ToolResult(f"error: {e}", str(e)[:200], ok=False)
    return ToolResult(to_text(out), summarize(out), ok=True)

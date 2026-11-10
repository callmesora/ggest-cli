"""MCP server (FastMCP, stdio) exposing the gGest BI tools to AI agents.

Run:          uv run ggest-mcp [--db path/to/data.sqlite]     (one server entry per gGest database)
Claude Code:  claude mcp add ggest -- uv run --directory <path>/inforbyte-bi ggest-mcp
Any client:   {"mcpServers": {"ggest": {"command": "uv",
                                        "args": ["run", "--directory", "<path>/inforbyte-bi", "ggest-mcp"]}}}

All tools are read-only. Amounts are net of VAT (EUR); the `data_dictionary` tool explains definitions.
"""

import functools
import sqlite3
from importlib.metadata import version
from pathlib import Path
from typing import Any

import click
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.tools import Tool as McpTool
from mcp.types import ToolAnnotations

from . import db
from .metrics import TOOLS  # importing bi.metrics registers every tool
from .registry import Tool

INSTRUCTIONS = (
    "Business data of a company using the gGest ERP (Golfinho Software): sales, customers, products, repairs "
    "(assistências), purchases, stock, receivables and expenses. Money is EUR net of VAT; credit notes are negative; "
    "cancelled and internal documents are excluded. Start with run_saved_query management_kpi_snapshot (it gives the "
    "data date: 'today' in queries means that date) and data_dictionary. Prefer named tools, then saved_queries "
    "(search by words), then `query` (read-only SQL on the business views). Quote periods and caveats in answers."
)
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)


def as_mcp_tool(t: Tool) -> McpTool:
    """Wrap a registry tool: same signature and schema, date words resolved before the call."""

    @functools.wraps(t.fn)
    def run(**kwargs: Any) -> Any:
        try:
            return t.call(**kwargs)
        except (ValueError, sqlite3.Error) as e:  # the agent's request was wrong: tell it why, no traceback
            raise ToolError(str(e)) from e

    return McpTool.from_function(run, name=t.name, description=t.description, annotations=READ_ONLY,
                                 output_schema=None)  # fmt: skip


def build_server() -> FastMCP:
    server = FastMCP("ggest-bi", instructions=INSTRUCTIONS, version=version("ggest-cli"))
    for t in TOOLS.values():
        server.add_tool(as_mcp_tool(t))
    return server


@click.command()
@click.option("--db", "db_file", type=click.Path(dir_okay=False, path_type=Path), help="SQLite database to use")
def main(db_file: Path | None) -> None:
    """Serve the tools over stdio."""
    if db_file:
        db.set_db(db_file)
    build_server().run(show_banner=False)


if __name__ == "__main__":
    main()

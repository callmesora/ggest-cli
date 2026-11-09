"""MCP server (stdio, no dependencies) exposing the Inforbyte BI tools to AI agents.

Run:   py -m bi.mcp_server [--db path/to/data.sqlite]   (one server entry per gGest database)
Claude Code:  claude mcp add inforbyte-bi -- py -m bi.mcp_server   (from the inforbyte-bi folder)
or add to an MCP client config:
  {"mcpServers": {"inforbyte-bi": {"command": "py", "args": ["-m", "bi.mcp_server"],
                                   "cwd": "<path>/inforbyte-bi"}}}

All tools are read-only. Amounts are net of VAT (EUR); see docs/DATA_DICTIONARY.md (also served as the
`data_dictionary` tool) for definitions.
"""
import json
import sys
import traceback
from pathlib import Path

from . import metrics, saved

PROTOCOL = "2025-06-18"
DICT = Path(__file__).resolve().parent.parent / "docs" / "DATA_DICTIONARY.md"
INSTRUCTIONS = (
    "Business data of a company using the gGest ERP (Golfinho Software): sales, customers, products, repairs "
    "(assistências), purchases, stock, receivables and expenses. Money is EUR net of VAT; credit notes are negative; "
    "cancelled and internal documents are excluded. Start with run_saved_query management_kpi_snapshot (it gives the "
    "data date: 'today' in queries means that date) and data_dictionary. Prefer named tools, then saved_queries "
    "(search by words), then `query` (read-only SQL on the business views). Quote periods and caveats in answers."
)


def tool_list():
    out = []
    for name, (_, desc, props) in metrics.TOOLS.items():
        out.append({"name": name, "description": desc,
                    "inputSchema": {"type": "object", "properties": props,
                                    "required": metrics.REQUIRED.get(name, [])}})
    return out


def call(name, args):
    if name not in metrics.TOOLS:
        raise ValueError(f"unknown tool {name}")
    fn = metrics.TOOLS[name][0]
    saved.LAST_TRUNCATED = False
    out = fn(**saved.resolve(args or {}))
    if saved.LAST_TRUNCATED:   # tell the model the list is incomplete, so it never sums a cut list
        out = {"rows": out, "truncated": True, "note": "more rows exist; call again with a higher limit for totals"}
    return json.dumps(out, ensure_ascii=False, default=str)


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:          # notification
        return None
    try:
        if method == "initialize":
            res = {"protocolVersion": msg.get("params", {}).get("protocolVersion", PROTOCOL),
                   "capabilities": {"tools": {}}, "instructions": INSTRUCTIONS,
                   "serverInfo": {"name": "ggest-bi", "version": "2.0.0"}}
        elif method == "tools/list":
            res = {"tools": tool_list()}
        elif method == "tools/call":
            p = msg.get("params", {})
            try:
                res = {"content": [{"type": "text", "text": call(p.get("name"), p.get("arguments"))}]}
            except Exception as e:  # tool errors are returned to the model, not as protocol errors
                res = {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}
        elif method == "ping":
            res = {}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}
        return {"jsonrpc": "2.0", "id": mid, "result": res}
    except Exception as e:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e),
                                                      "data": traceback.format_exc()[-2000:]}}


def main():
    if "--db" in sys.argv:
        from . import db
        db.set_db(sys.argv[sys.argv.index("--db") + 1])
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        out = handle(msg)
        if out is not None:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

"""Plain-text rendering of tool results for the terminal."""

import json
from typing import Any

MAX_WIDTH = 40


def to_json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, default=str)


def cell(value: Any) -> str:
    if isinstance(value, float):
        return f"{value:,.2f}"
    return "" if value is None else str(value)


def _as_records(data: Any) -> Any:
    """{columns, rows} (from `query`) or {rows, truncated} (a cut saved query) -> list of dicts."""
    if isinstance(data, dict) and "columns" in data and "rows" in data:
        return [dict(zip(data["columns"], r, strict=True)) for r in data["rows"]]
    if isinstance(data, dict) and isinstance(data.get("rows"), list) and data.get("truncated"):
        return data["rows"]
    return data


def table(data: Any) -> str:
    """Column-aligned text table for a list of dicts; JSON for other dicts; text as is."""
    data = _as_records(data)
    if isinstance(data, str):
        return data
    if isinstance(data, dict):
        return to_json(data)
    if not data:
        return "(no rows)"
    cols = list(data[0].keys())
    cells = [[cell(r.get(c)) for c in cols] for r in data]
    widths = [min(MAX_WIDTH, max(len(c), *(len(row[i]) for row in cells))) for i, c in enumerate(cols)]

    def line(values: list[str]) -> str:
        return "  ".join(v[:w].ljust(w) for v, w in zip(values, widths, strict=True))

    return "\n".join([line(cols), line(["-" * w for w in widths]), *map(line, cells)])


def query_list(queries: list[dict[str, Any]]) -> str:
    """Saved queries, one block each: name, domain, params, then the summary (or the full description)."""
    blocks = [
        f"{q['name']}  [{q['domain']}]  params: {q['params']}\n    {q.get('summary') or q.get('description')}\n"
        for q in queries
    ]
    hint = "--name <query> shows one in full; --full shows every description in full"
    return "\n".join([*blocks, f"{len(queries)} saved queries ({hint})"])


def is_truncated(data: Any) -> bool:
    return isinstance(data, dict) and bool(data.get("truncated"))


def _is_records(data: Any) -> bool:
    return isinstance(data, list) and bool(data) and all(isinstance(r, dict) for r in data)


def columnar(records: list[dict[str, Any]]) -> dict[str, Any]:
    """[{a: 1, b: 2}, {a: 3, b: 4}] -> {columns: [a, b], rows: [[1, 2], [3, 4]]}: names once, not on every row."""
    cols = list(dict.fromkeys(k for r in records for k in r))
    return {"columns": cols, "rows": [[r.get(c) for c in cols] for r in records]}


def compact(data: Any) -> Any:
    """Token-lean shape for agents: every list of records (also nested, e.g. in a profile) becomes columns + rows;
    a cut result {rows: [...], truncated, note} keeps its flags next to the columns."""
    if _is_records(data):
        return columnar(data)
    if isinstance(data, dict):
        if _is_records(data.get("rows")):
            return {**columnar(data["rows"]), **{k: v for k, v in data.items() if k != "rows"}}
        return {k: compact(v) for k, v in data.items()}
    return data

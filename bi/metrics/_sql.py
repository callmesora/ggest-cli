"""Small SQL helpers shared by the metric modules."""

from typing import Any


def where(
    start: str | None = None, end: str | None = None, extra: list[str] | None = None, date_col: str = "doc_date"
) -> tuple[str, list[Any]]:
    """WHERE clause for an inclusive date range plus extra conditions; returns (sql, params)."""
    conds, params = [], []
    if start:
        conds.append(f"{date_col} >= ?")
        params.append(start)
    if end:
        conds.append(f"{date_col} <= ?")
        params.append(end)
    conds.extend(extra or [])
    return ("WHERE " + " AND ".join(conds)) if conds else "", params


def rnd(value: Any, digits: int = 2) -> Any:
    return round(value, digits) if isinstance(value, float) else value


def clean(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Round floats to cents."""
    return [{k: rnd(v) for k, v in r.items()} for r in rows]


def pick_one(matches: list[dict[str, Any]], key: str, query: str, what: str) -> dict[str, Any]:
    """The exact match on `key`, or the only match; {'ambiguous': [...]} / {'error': ...} otherwise."""
    if not matches:
        return {"error": f"no {what} matches {query!r}"}
    exact = next((m for m in matches if m[key] == query), None)
    if exact:
        return exact
    return matches[0] if len(matches) == 1 else {"ambiguous": matches}

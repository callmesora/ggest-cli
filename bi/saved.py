"""Saved-query library: every bi/queries/<domain>/*.sql file is a reusable, documented query.

File format (header comments, then ONE SELECT/WITH statement):
    -- name: repairs_by_brand_year
    -- description: Repairs per brand per year (top brands)
    -- params: start=2017-01-01, end=today, limit=20
    SELECT ... WHERE opened_on BETWEEN :start AND :end ... LIMIT :limit

Params use SQLite named placeholders (:start); defaults come from the `params` line and may be date words
(see bi.dates). Exposed as the tools `saved_queries` (search) and `run_saved_query`.
"""

import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import dates, db

QUERIES = Path(__file__).resolve().parent / "queries"
_META = re.compile(r"^--\s*(name|description|params|domain):\s*(.*)$", re.MULTILINE)
_INT = re.compile(r"-?\d+")
_FLOAT = re.compile(r"-?\d+\.\d+")

# kept for older imports
date_words = dates.date_words
resolve = dates.resolve


@dataclass(frozen=True)
class SavedQuery:
    name: str
    domain: str
    description: str
    params: dict[str, Any]
    sql: str
    file: Path

    def summary(self) -> dict[str, Any]:
        return {"name": self.name, "domain": self.domain, "description": self.description, "params": self.params}

    def matches(self, domain: str | None, words: list[str]) -> bool:
        text = f"{self.name} {self.description}".lower()
        return (not domain or self.domain == domain) and all(w in text for w in words)


@dataclass(frozen=True)
class Page:
    """Rows of a result, and whether more rows existed than the limit."""

    rows: list[dict[str, Any]]
    truncated: bool


def parse_value(text: str) -> Any:
    """'10' -> 10, '1.5' -> 1.5, anything else stays text."""
    text = text.strip()
    if _INT.fullmatch(text):
        return int(text)
    if _FLOAT.fullmatch(text):
        return float(text)
    return text


def parse_params_line(line: str) -> dict[str, Any]:
    """'start=2017-01-01, limit=20' -> {'start': '2017-01-01', 'limit': 20}."""
    out = {}
    for part in filter(None, (p.strip() for p in line.split(","))):
        key, _, value = part.partition("=")
        out[key.strip()] = parse_value(value)
    return out


def parse(path: Path) -> SavedQuery:
    text = path.read_text(encoding="utf-8")
    meta = dict(_META.findall(text))
    sql = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("--")).strip().rstrip(";")
    return SavedQuery(
        name=meta.get("name", path.stem),
        domain=meta.get("domain", path.parent.name),
        description=meta.get("description", ""),
        params=parse_params_line(meta.get("params", "")),
        sql=sql,
        file=path,
    )


def catalog() -> dict[str, SavedQuery]:
    return {q.name: q for q in map(parse, sorted(QUERIES.rglob("*.sql")))}


def get(name: str) -> SavedQuery:
    query = catalog().get(name)
    if not query:
        raise ValueError(f"unknown saved query {name!r}; search with saved_queries")
    return query


def saved_queries(domain: str | None = None, search: str | None = None, name: str | None = None) -> Any:
    """List saved queries (name, domain, description, params) filtered by domain and/or words in the name or
    description; `name` returns one query in full, with its SQL."""
    if name:
        query = get(name)
        return {**query.summary(), "sql": query.sql}
    words = (search or "").lower().split()
    return [q.summary() for q in catalog().values() if q.matches(domain, words)]


def _round(value: Any) -> Any:
    return round(value, 2) if isinstance(value, float) else value


def run_page(name: str, params: dict[str, Any] | None = None, limit: int = 500) -> Page:
    """Run a saved query by name; `params` override its defaults. Says whether rows were cut at `limit`."""
    query = get(name)
    values = dates.resolve({**query.params, **(params or {})})
    limit = int(limit)
    with db.reading() as con:
        cur = con.execute(query.sql, values)
        cols = [c[0] for c in cur.description]
        data = cur.fetchmany(limit + 1)
    rows = [dict(zip(cols, map(_round, r), strict=True)) for r in data[:limit]]
    return Page(rows, truncated=len(data) > limit)


def run_saved_query(name: str, params: dict[str, Any] | None = None, limit: int = 500) -> list[dict[str, Any]]:
    """Run a saved query by name; `params` override its defaults (rows only)."""
    return run_page(name, params, limit).rows


def check(domain: str | None = None) -> list[dict[str, Any]]:
    """Run every saved query with its defaults: name, rows, seconds, error (tests the library)."""
    out = []
    for query in catalog().values():
        if domain and query.domain != domain:
            continue
        started = time.perf_counter()
        try:
            count, error = len(run_saved_query(query.name, limit=100_000)), ""
        except Exception as e:  # noqa: BLE001 - report every failure, keep going
            count, error = None, str(e)[:200]
        secs = round(time.perf_counter() - started, 2)
        out.append({"name": query.name, "rows": count, "secs": secs, "error": error})
    return out

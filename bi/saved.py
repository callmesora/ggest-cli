"""Saved-query library: every bi/queries/**/*.sql file is a reusable, documented query.

File format (header comments, then ONE SELECT/WITH statement):
    -- name: repairs_by_brand_year
    -- description: Repairs per brand per year (top brands)
    -- params: start=2017-01-01, end=2026-12-31, limit=20
    SELECT ... WHERE opened_on BETWEEN :start AND :end ... LIMIT :limit

Params use SQLite named placeholders (:start). Defaults come from the `params` line.
Exposed as tools `saved_queries` (list) and `run_saved_query` (CLI and MCP).
"""
import re
from pathlib import Path

from . import db

QUERIES = Path(__file__).resolve().parent / "queries"


def _parse(path):
    text = path.read_text(encoding="utf-8")
    meta = dict(re.findall(r"^--\s*(name|description|params|domain):\s*(.*)$", text, re.M))
    defaults = {}
    for part in filter(None, (p.strip() for p in meta.get("params", "").split(","))):
        k, _, v = part.partition("=")
        v = v.strip()
        defaults[k.strip()] = int(v) if re.fullmatch(r"-?\d+", v) else (float(v) if re.fullmatch(r"-?\d+\.\d+", v) else v)
    sql = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--")).strip().rstrip(";")
    return {"name": meta.get("name", path.stem), "description": meta.get("description", ""),
            "domain": meta.get("domain", path.parent.name), "params": defaults, "sql": sql, "file": str(path)}


def catalog():
    return {q["name"]: q for q in (_parse(p) for p in sorted(QUERIES.rglob("*.sql")))}


def saved_queries(domain=None):
    """List saved queries (name, domain, description, params)."""
    return [{k: q[k] for k in ("name", "domain", "description", "params")}
            for q in catalog().values() if not domain or q["domain"] == domain]


def run_saved_query(name, params=None, limit=500):
    """Run a saved query by name; `params` overrides defaults (dict)."""
    q = catalog().get(name)
    if not q:
        raise ValueError(f"unknown saved query {name!r}")
    p = dict(q["params"]); p.update(params or {})
    con = db.connect(read_only=True)
    try:
        cur = con.execute(q["sql"], p)
        cols = [c[0] for c in cur.description]
        data = cur.fetchmany(int(limit))
        return [dict(zip(cols, (round(v, 2) if isinstance(v, float) else v for v in r))) for r in data]
    finally:
        con.close()

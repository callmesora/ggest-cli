"""Saved-query library: every bi/queries/**/*.sql file is a reusable, documented query.

File format (header comments, then ONE SELECT/WITH statement):
    -- name: repairs_by_brand_year
    -- description: Repairs per brand per year (top brands)
    -- params: start=2017-01-01, end=2026-12-31, limit=20
    SELECT ... WHERE opened_on BETWEEN :start AND :end ... LIMIT :limit

Params use SQLite named placeholders (:start). Defaults come from the `params` line.
Date words (as defaults or passed values): today = last document date in the data (the snapshot date),
this_year / last_year (e.g. 2026), year_start / last_year_start / last_year_end (ISO dates),
today_last_year (same day one year earlier, for year-to-date comparisons), today_mmdd (e.g. 11-08),
years_ago_3 (e.g. 2023).
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


def saved_queries(domain=None, search=None, name=None):
    """List saved queries (name, domain, description, params); filter by domain and/or words in name/description;
    `name` = one query in full (description, params and SQL)."""
    if name:
        q = catalog().get(name)
        if not q:
            raise ValueError(f"unknown saved query {name!r}")
        return {k: q[k] for k in ("name", "domain", "description", "params", "sql")}
    words = (search or "").lower().split()
    out = []
    for q in catalog().values():
        text = (q["name"] + " " + q["description"]).lower()
        if (not domain or q["domain"] == domain) and all(w in text for w in words):
            out.append({k: q[k] for k in ("name", "domain", "description", "params")})
    return out


def check(domain=None):
    """Run every saved query with its defaults: name, rows, seconds, error (for testing the library)."""
    import time
    out = []
    for q in catalog().values():
        if domain and q["domain"] != domain:
            continue
        t = time.time()
        try:
            n, err = len(run_saved_query(q["name"], limit=100000)), ""
        except Exception as e:      # noqa: BLE001 - report every failure
            n, err = None, str(e)[:200]
        out.append({"name": q["name"], "rows": n, "secs": round(time.time() - t, 2), "error": err})
    return out


_DATES = None
LAST_TRUNCATED = False      # set by run_saved_query: more rows existed than `limit`
_WORDS = ("today", "this_year", "last_year", "year_start", "last_year_start", "last_year_end", "today_last_year",
          "today_mmdd", "years_ago_3")


def date_words():
    """today = latest sales/repair date in the database, so old snapshots answer as of their own date."""
    global _DATES
    if _DATES is None:
        import datetime as dt
        con = db.connect(read_only=True)
        try:
            d = con.execute("SELECT MAX(doc_date) FROM sales_docs WHERE doc_date <= date('now')").fetchone()[0]
        finally:
            con.close()
        today = dt.date.fromisoformat(d[:10]) if d else dt.date.today()
        try:
            tly = today.replace(year=today.year - 1)
        except ValueError:
            tly = today.replace(year=today.year - 1, day=28)
        _DATES = {"today": today.isoformat(), "this_year": today.year, "last_year": today.year - 1,
                  "year_start": f"{today.year}-01-01", "last_year_start": f"{today.year - 1}-01-01",
                  "last_year_end": f"{today.year - 1}-12-31", "today_last_year": tly.isoformat(),
                  "today_mmdd": today.strftime("%m-%d"), "years_ago_3": today.year - 3}
    return _DATES


def resolve(args):
    """Replace date words in tool arguments (used by the CLI and MCP server for every tool)."""
    if not any(isinstance(v, str) and v in _WORDS for v in args.values()):
        return args
    w = date_words()
    return {k: w.get(v, v) if isinstance(v, str) else v for k, v in args.items()}


def run_saved_query(name, params=None, limit=500):
    """Run a saved query by name; `params` overrides defaults (dict)."""
    q = catalog().get(name)
    if not q:
        raise ValueError(f"unknown saved query {name!r}")
    p = dict(q["params"]); p.update(params or {})
    if any(isinstance(v, str) and v in _WORDS for v in p.values()):
        w = date_words()
        p = {k: w.get(v, v) if isinstance(v, str) else v for k, v in p.items()}
    con = db.connect(read_only=True)
    try:
        cur = con.execute(q["sql"], p)
        cols = [c[0] for c in cur.description]
        data = cur.fetchmany(int(limit) + 1)
        global LAST_TRUNCATED
        LAST_TRUNCATED = len(data) > int(limit)
        return [dict(zip(cols, (round(v, 2) if isinstance(v, float) else v for v in r))) for r in data[:int(limit)]]
    finally:
        con.close()

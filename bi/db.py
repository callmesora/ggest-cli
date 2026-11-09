"""Database access for the Inforbyte BI toolkit.

The database is the SQLite file built by `pipeline/build_sqlite.py` from the gGest (HFSQL) export.
Path: env var INFORBYTE_DB, else <project>/data/data.sqlite.
"""
import os
import re
import sqlite3
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
SEMANTIC_SQL = Path(__file__).resolve().parent / "sql" / "semantic.sql"


def db_path():
    return Path(os.environ.get("INFORBYTE_DB", PROJECT / "data" / "data.sqlite"))


def connect(read_only=True):
    p = db_path()
    if not p.exists():
        raise FileNotFoundError(f"database not found: {p} (build it with pipeline/build_sqlite.py)")
    if read_only:
        con = sqlite3.connect(f"file:{p.as_posix()}?mode=ro", uri=True)
    else:
        con = sqlite3.connect(p, timeout=300)   # waits for readers to finish
    con.row_factory = sqlite3.Row
    return con


def build_views():
    """(Re)create the business views (idempotent)."""
    con = connect(read_only=False)
    for name in ("product_cost_ratios", "sales_facts"):   # older builds had these as views
        if con.execute("SELECT 1 FROM sqlite_master WHERE type='view' AND name=?", (name,)).fetchone():
            con.execute(f"DROP VIEW {name}")
    con.executescript(SEMANTIC_SQL.read_text(encoding="utf-8"))
    con.commit()
    names = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='view' ORDER BY name")]
    con.close()
    return names


def rows(sql, params=(), limit=None):
    """Run a query and return a list of dicts."""
    con = connect()
    try:
        cur = con.execute(sql, params)
        out = cur.fetchmany(limit) if limit else cur.fetchall()
        return [dict(r) for r in out]
    finally:
        con.close()


_FORBIDDEN = re.compile(r"\b(insert|update|delete|drop|alter|create|replace|attach|detach|pragma|vacuum|reindex)\b", re.I)


# gGest stores user passwords readably (utilizadores.password) and service credentials (Broker.PalavraPasse):
# never expose them to agents.
_SECRET = re.compile(r"\b(password|palavrapasse|pwd\w*|senha\w*|utilizadores|broker)\b", re.I)


def safe_query(sql, limit=500):
    """Read-only ad-hoc SQL for agents: single SELECT/WITH statement, row cap, read-only connection."""
    s = sql.strip().rstrip(";")
    if ";" in s:
        raise ValueError("only one statement allowed")
    if not re.match(r"(?is)^\s*(select|with)\b", s):
        raise ValueError("only SELECT / WITH queries are allowed")
    if _FORBIDDEN.search(s):
        raise ValueError("write/DDL keywords are not allowed")
    if _SECRET.search(s):
        raise ValueError("password columns are not available through this tool")
    con = connect(read_only=True)
    try:
        cur = con.execute(s)
        cols = [c[0] for c in cur.description]
        data = cur.fetchmany(limit + 1)
        truncated = len(data) > limit
        return {"columns": cols, "rows": [list(r) for r in data[:limit]], "truncated": truncated}
    finally:
        con.close()

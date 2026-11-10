"""Database access for the gGest BI toolkit.

The database is the SQLite file built by `pipeline/build_sqlite.py` from the gGest (HFSQL) export.
Path: set_db() / CLI --db / env GGEST_DB (or INFORBYTE_DB), else <project>/data/data.sqlite.
Business views: bi/sql/semantic.sql, then every bi/sql/ext/*.sql (one file per domain), in name order.
"""

import os
import sqlite3
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import security

PROJECT = Path(__file__).resolve().parent.parent
SQL_DIR = Path(__file__).resolve().parent / "sql"
SEMANTIC_SQL = SQL_DIR / "semantic.sql"
_LEGACY_VIEWS = ("product_cost_ratios", "sales_facts")  # older builds had these as views, now tables


@dataclass
class _State:
    path: Path | None = None


_state = _State()


def set_db(path: str | Path | None) -> None:
    """Point the toolkit at another gGest database (one SQLite file per company/database)."""
    _state.path = Path(path) if path else None


def db_path() -> Path:
    if _state.path:
        return _state.path
    env = os.environ.get("GGEST_DB") or os.environ.get("INFORBYTE_DB")
    return Path(env) if env else PROJECT / "data" / "data.sqlite"


def view_files() -> list[Path]:
    return [SEMANTIC_SQL, *sorted((SQL_DIR / "ext").glob("*.sql"))]


def connect(*, read_only: bool = True) -> sqlite3.Connection:
    path = db_path()
    if not path.exists():
        raise FileNotFoundError(f"database not found: {path} (build it with pipeline/build_sqlite.py)")
    if read_only:  # waits while views are being rebuilt
        con = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True, timeout=60)
    else:  # waits for readers to finish
        con = sqlite3.connect(path, timeout=300)
    con.row_factory = sqlite3.Row
    return con


@contextmanager
def reading() -> Iterator[sqlite3.Connection]:
    """Read-only connection, closed on exit."""
    con = connect(read_only=True)
    try:
        yield con
    finally:
        con.close()


def build_views(file: str | Path | None = None) -> list[str]:
    """(Re)create the business views (idempotent). `file`: apply only that .sql file (e.g. a bi/sql/ext file)."""
    from . import config  # noqa: PLC0415 - config imports db

    con = connect(read_only=False)
    try:
        for name in _LEGACY_VIEWS:
            if con.execute("SELECT 1 FROM sqlite_master WHERE type='view' AND name=?", (name,)).fetchone():
                con.execute(f"DROP VIEW {name}")
        if not file:
            config.apply(con)
        for sql_file in [Path(file)] if file else view_files():
            try:
                con.executescript(sql_file.read_text(encoding="utf-8"))
            except sqlite3.Error as e:
                raise RuntimeError(f"{sql_file.name}: {e}") from e
        con.commit()
        return [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='view' ORDER BY name")]
    finally:
        con.close()


def rows(sql: str, params: Sequence[Any] | dict[str, Any] = (), limit: int | None = None) -> list[dict[str, Any]]:
    """Run a query and return a list of dicts."""
    with reading() as con:
        cur = con.execute(sql, params)
        return [dict(r) for r in (cur.fetchmany(limit) if limit else cur.fetchall())]


def fetch_page(cur: sqlite3.Cursor, limit: int, offset: int = 0) -> tuple[list[Any], bool]:
    """Rows offset..offset+limit of a cursor, and whether more rows follow."""
    if offset:
        cur.fetchmany(offset)  # skip earlier pages
    data = cur.fetchmany(limit + 1)
    return data[:limit], len(data) > limit


def safe_query(sql: str, limit: int = 500, offset: int = 0) -> dict[str, Any]:
    """Read-only ad-hoc SQL for agents: single SELECT/WITH statement, row cap, read-only connection."""
    statement = security.check_read_only(sql)
    with reading() as con:
        cur = con.execute(statement)
        cols = [c[0] for c in cur.description]
        if any(security.is_secret_column(c) for c in cols):  # e.g. SELECT * on a table with a credential column
            raise ValueError(security.SECRET_MESSAGE)
        data, more = fetch_page(cur, limit, offset)
    out = {"columns": cols, "rows": [list(r) for r in data], "truncated": more}
    return {**out, "next_offset": offset + limit} if more else out

"""Database access for the Inforbyte BI toolkit.

The database is the SQLite file built by `pipeline/build_sqlite.py` from the gGest (HFSQL) export.
Path: set_db() / CLI --db / env GGEST_DB (or INFORBYTE_DB), else <project>/data/data.sqlite.
Business views: bi/sql/semantic.sql, then every bi/sql/ext/*.sql (one file per domain), in name order.
"""
import os
import re
import sqlite3
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
SQL_DIR = Path(__file__).resolve().parent / "sql"
SEMANTIC_SQL = SQL_DIR / "semantic.sql"
_DB = None


def set_db(path):
    """Point the toolkit at another gGest database (one SQLite file per company/database)."""
    global _DB
    _DB = Path(path) if path else None


def db_path():
    if _DB:
        return _DB
    return Path(os.environ.get("GGEST_DB") or os.environ.get("INFORBYTE_DB") or PROJECT / "data" / "data.sqlite")


def view_files():
    return [SEMANTIC_SQL] + sorted((SQL_DIR / "ext").glob("*.sql"))


def connect(read_only=True):
    p = db_path()
    if not p.exists():
        raise FileNotFoundError(f"database not found: {p} (build it with pipeline/build_sqlite.py)")
    if read_only:
        con = sqlite3.connect(f"file:{p.as_posix()}?mode=ro", uri=True, timeout=60)   # waits while views are rebuilt
    else:
        con = sqlite3.connect(p, timeout=300)   # waits for readers to finish
    con.row_factory = sqlite3.Row
    return con


def build_views(file=None):
    """(Re)create the business views (idempotent). `file`: apply only that one .sql file (e.g. a bi/sql/ext file)."""
    con = connect(read_only=False)
    for name in ("product_cost_ratios", "sales_facts"):   # older builds had these as views
        if con.execute("SELECT 1 FROM sqlite_master WHERE type='view' AND name=?", (name,)).fetchone():
            con.execute(f"DROP VIEW {name}")
    if not file:
        from . import config
        config.apply(con)
    for f in ([Path(file)] if file else view_files()):
        try:
            con.executescript(f.read_text(encoding="utf-8"))
        except sqlite3.Error as e:
            raise RuntimeError(f"{f.name}: {e}") from e
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


# gGest stores credentials readably: user passwords (utilizadores), e-mail/SMTP, web-shop, POS and workshop
# terminal passwords, API keys and tokens, licence keys, bank account numbers. Agents never get them: these
# tables are refused, and so is any query that names or returns a column that looks like a credential.
_SECRET_TABLES = ("utilizadores", "broker", "contas_mail", "email_configuracao", "emails_perfil_contas", "ecom_lojas",
                  "dropbox_contas", "sms_contas", "ia_extratordados", "mobivendas_terminais", "oficina_mecanicos",
                  "oficina_terminais_recepcao", "oficina_terminais_recolha", "licencas", "licencas_registos",
                  "conf_sistema", "contas_bancarias", "frlock", "terminais_mobistock", "perfisutl")
_SECRET_COLS = r"\w*password\w*|palavrapasse|pwd\w*|senha\w*|\w*token\w*|chave\w*|nib\w*|iban\w*|swift|\w*_iban\w*|numero_cartao"
_SECRET = re.compile(r"\b(" + "|".join(_SECRET_TABLES) + "|" + _SECRET_COLS + r")\b", re.I)
_SECRET_COL = re.compile(r"^(" + _SECRET_COLS + r")$", re.I)


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
        if any(_SECRET_COL.match(c) for c in cols):     # e.g. SELECT * on a table holding a credential column
            raise ValueError("password columns are not available through this tool")
        data = cur.fetchmany(limit + 1)
        truncated = len(data) > limit
        return {"columns": cols, "rows": [list(r) for r in data[:limit]], "truncated": truncated}
    finally:
        con.close()

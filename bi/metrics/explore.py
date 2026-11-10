"""Tools for open questions: definitions, the saved-query library, view columns and read-only SQL."""

from typing import Annotated, Any

from pydantic import Field

from .. import db, saved, security
from ..registry import tool

DOCS = db.PROJECT / "docs"
TRUNCATED_NOTE = "more rows exist; call again with a higher limit for totals"


def _topics() -> list[str]:
    return sorted(p.stem for p in (DOCS / "domains").glob("*.md"))


@tool(
    "Read first: business definitions, rules and caveats; topic=<domain> for a domain's tables, codes and traps "
    "(sales, customers, repairs, finance, stock, operations)."
)
def data_dictionary(topic: str | None = None) -> str:
    """Definitions and rules (docs/DATA_DICTIONARY.md), or one domain's notes (docs/domains/<topic>.md)."""
    topics = _topics()
    if topic:
        if topic not in topics:
            raise ValueError(f"unknown topic {topic!r}; topics: {', '.join(topics)}")
        return (DOCS / "domains" / f"{topic}.md").read_text(encoding="utf-8")
    note = f"Domain notes (data_dictionary --topic X): {', '.join(topics)}"
    return (DOCS / "DATA_DICTIONARY.md").read_text(encoding="utf-8") + "\n\n" + note + "\n"


@tool(
    "Search the saved-query library (documented SQL for most business questions). Filter by domain folder "
    "(sales, customers, repairs, finance, stock, management, ...) and/or words in name/description; "
    "name=<query> shows one query with its SQL."
)
def saved_queries(domain: str | None = None, search: str | None = None, name: str | None = None) -> Any:
    """See bi.saved.saved_queries."""
    return saved.saved_queries(domain, search, name)


@tool("Run a saved query by name; params override its defaults (date words allowed).")
def run_saved_query(
    name: str,
    params: Annotated[dict[str, Any] | None, Field(description='overrides, e.g. {"start": "2025-01-01"}')] = None,
    limit: int = 500,
) -> Any:
    """Rows of the query; when more rows existed than `limit`: {rows, truncated, note} so nobody sums a cut list."""
    page = saved.run_page(name, params, limit)
    if page.truncated:
        return {"rows": page.rows, "truncated": True, "note": TRUNCATED_NOTE}
    return page.rows


@tool("List business views, or columns + sample rows of one view/table.")
def describe(name: str | None = None) -> Any:
    """Business views (or one view's columns). Prefer these over raw gGest tables."""
    if not name:
        return db.rows("SELECT name, type FROM sqlite_master WHERE type='view' ORDER BY name")
    if security.mentions_secret(name):
        return {"error": f"{name} holds passwords and is not available through this tool"}
    cols = [c["name"] for c in db.rows("SELECT name FROM pragma_table_info(?)", (name,))]
    if not cols:
        raise ValueError(f"no view or table named {name!r}; `describe` without a name lists the views")
    visible = [c for c in cols if not security.is_secret_column(c)]
    if len(visible) < len(cols):
        return {"name": name, "columns": ", ".join(visible),
                "note": "credential columns hidden; table not queryable as SELECT *"}  # fmt: skip
    return {"name": name, "columns": ", ".join(cols), "sample": db.rows(f'SELECT * FROM "{name}" LIMIT 2')}


@tool(
    "Read-only SQL (single SELECT/WITH) for questions the other tools don't cover. "
    "Use business views (sales_facts, sales_docs, customers, items, repairs, purchase_docs)."
)
def query(sql: str, limit: int = 200) -> dict:
    """Read-only SQL over business views and raw tables. Max `limit` rows."""
    return db.safe_query(sql, int(limit))

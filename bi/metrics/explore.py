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
    "READ FIRST. Business definitions, rules and caveats (money net of VAT, what is excluded, margin "
    "method, data date). topic=sales|customers|repairs|finance|stock|operations returns that domain's "
    "views, codes and traps; read it before writing SQL on that domain."
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
    "Find a saved query (139 documented SQL queries covering most business questions) by words and/or "
    "domain (sales, customers, repairs, finance, stock, operations, management, setup). Returns one line "
    "per query: name, domain, summary, params with defaults. name=<query> returns its full description "
    "and SQL; full=true returns full descriptions for the whole list. Then call run_saved_query."
)
def saved_queries(
    domain: str | None = None,
    search: Annotated[str | None, Field(description="words that must all appear in the name or description")] = None,
    name: Annotated[str | None, Field(description="one query: full description, params and SQL")] = None,
    full: bool = False,
) -> Any:
    """See bi.saved.saved_queries."""
    return saved.saved_queries(domain, search, name, full=full)


@tool(
    "Run a saved query by name (find names with saved_queries). params override its defaults and accept "
    "date words (today, year_start, last_year_start, today_last_year...). Returns columns + rows; when "
    "more rows exist than limit, truncated=true: never sum a truncated list, raise limit or use a summary"
    " query."
)
def run_saved_query(
    name: Annotated[str, Field(description="saved query name, from saved_queries")],
    params: Annotated[dict[str, Any] | None, Field(description='overrides, e.g. {"start": "2025-01-01"}')] = None,
    limit: Annotated[int, Field(description="maximum rows returned")] = 100,
) -> Any:
    """Rows of the query; when more rows existed than `limit`: {rows, truncated, note} so nobody sums a cut list."""
    page = saved.run_page(name, params, limit)
    if page.truncated:
        return {"rows": page.rows, "truncated": True, "note": TRUNCATED_NOTE}
    return page.rows


@tool(
    "Without name: the business views (query these, not raw gGest tables). With name: the columns of one "
    "view/table and a sample row. Use before writing SQL with the query tool."
)
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
    return {"name": name, "columns": ", ".join(cols), "sample": db.rows(f'SELECT * FROM "{name}" LIMIT 1')}


@tool(
    "Last resort when no named tool or saved query fits: one read-only SELECT/WITH statement over the "
    "business views (sales_facts, sales_docs, customers, customer_dim, items, repairs, purchase_docs, "
    "receivable_docs...; see describe and data_dictionary). Max limit rows. Credential tables/columns are"
    " refused."
)
def query(sql: str, limit: int = 200) -> dict:
    """Read-only SQL over business views and raw tables. Max `limit` rows."""
    return db.safe_query(sql, int(limit))

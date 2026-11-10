"""Purchasing tools: suppliers and purchases vs sales."""

from typing import Literal

from .. import db
from ..registry import DateArg, LimitArg, tool
from ._sql import clean, rnd, where
from .sales import sales_over_time


@tool(
    "Net purchases per supplier in a period (credit notes negative, cancelled excluded), biggest first: "
    "supplier_code, supplier, net_purchases, documents, last_purchase."
)
def purchases_by_supplier(start: DateArg = None, end: DateArg = None, limit: LimitArg = 20) -> list[dict]:
    """Net purchases per supplier (credit notes negative, cancelled excluded)."""
    w, p = where(start, end, ["is_cancelled = 0"])
    return clean(
        db.rows(
            f"""SELECT supplier_code, MAX(supplier_name) AS supplier, SUM(net) AS net_purchases,
                             COUNT(*) AS documents, MAX(doc_date) AS last_purchase
                             FROM purchase_docs {w} GROUP BY 1 ORDER BY 3 DESC LIMIT ?""",
            [*p, int(limit)],
        )
    )


@tool(
    "Purchases vs sales per year or month: net_sales, gross_margin, margin_pct and net_purchases per "
    "period (a cash view of stock investment)."
)
def purchases_vs_sales(
    period: Literal["year", "month"] = "year", start: DateArg = None, end: DateArg = None
) -> list[dict]:
    """Purchases vs sales per period (cash view of stock investment)."""
    w, p = where(start, end, ["is_cancelled = 0"])
    sql = f"SELECT {period} AS period, SUM(net) AS v FROM purchase_docs {w} GROUP BY 1"
    purchases = {r["period"]: r["v"] for r in db.rows(sql, p)}
    out = sales_over_time(period, start, end)
    for r in out:
        r["net_purchases"] = rnd(purchases.get(r["period"]))
    return out

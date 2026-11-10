"""Customer tools: rankings, concentration, one customer's profile, win-back list."""

from typing import Literal

from .. import db
from ..registry import DateArg, LimitArg, tool
from ._sql import clean, pick_one, where

Segment = Literal["publico", "empresa", "particular", "associativo"]
_NOT_WALK_IN = "customer_code NOT IN (SELECT customer_code FROM customers WHERE is_walk_in = 1)"


@tool(
    "Customers (per customer code) ranked by net sales, margin or invoices; optional segment filter. "
    "For legal entities merged by NIF use saved query customers_top_entities."
)
def top_customers(
    start: DateArg = None,
    end: DateArg = None,
    by: Literal["net", "margin", "invoices"] = "net",
    limit: LimitArg = 20,
    include_walk_in: bool = False,
    segment: Segment | None = None,
) -> list[dict]:
    """Customers ranked by net sales, margin or invoices, with first/last purchase and the repair orders of that
    customer code (all time). segment: publico | empresa | particular | associativo (customer_dim)."""
    order = {"net": "net_sales", "margin": "gross_margin", "invoices": "invoices"}[by]
    extra = [] if include_walk_in else [_NOT_WALK_IN]
    if segment:
        extra.append("customer_code IN (SELECT customer_code FROM customer_dim WHERE segment = ?)")
    w, p = where(start, end, extra)
    p += [segment] if segment else []  # extra conditions come after the date params
    return clean(
        db.rows(
            f"""
        WITH s AS (
          SELECT customer_code, MAX(customer_name) AS customer, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
                 COUNT(DISTINCT doc_id) AS invoices, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase
          FROM sales_facts {w} GROUP BY customer_code)
        SELECT s.*, 100.0*gross_margin/NULLIF(net_sales,0) AS margin_pct,
               (SELECT COUNT(*) FROM repairs r WHERE r.customer_code = s.customer_code)
                 AS repair_orders_this_code_all_time
        FROM s ORDER BY {order} DESC LIMIT ?""",
            [*p, int(limit)],
        )
    )


@tool("Share of sales from the top 1/10/20/50/100 customers.")
def customer_concentration(start: DateArg = None, end: DateArg = None) -> dict:
    """How dependent sales are on top customers."""
    w, p = where(start, end)
    values = [r["v"] or 0 for r in db.rows(
        f"SELECT customer_code, SUM(net) AS v FROM sales_facts {w} GROUP BY 1 ORDER BY v DESC", p)]  # fmt: skip
    total = sum(values) or 1
    out = {"customers": len(values), "net_sales": round(total, 2)}
    for n in (1, 10, 20, 50, 100):
        out[f"top{n}_share_pct"] = round(100 * sum(values[:n]) / total, 1)
    return out


@tool("Full profile of one customer by code, NIF or part of the name.")
def customer_profile(query: str, limit_items: int = 15) -> dict:
    """Everything about one customer: totals per year, top items, repairs."""
    matches = db.rows("""SELECT customer_code, name, nif, email, phone, opened_on, is_walk_in FROM customers
                         WHERE customer_code = ? OR lower(name) LIKE lower(?) OR nif = ? LIMIT 10""",
                      (query, f"%{query}%", query))  # fmt: skip
    customer = pick_one(matches, "customer_code", query, "customer")
    if "customer_code" not in customer:
        return customer
    code = customer["customer_code"]
    customer["sales_by_year"] = clean(
        db.rows(
            """
        SELECT year, SUM(net) AS net_sales, SUM(margin) AS gross_margin, COUNT(DISTINCT doc_id) AS invoices
        FROM sales_facts WHERE customer_code = ? GROUP BY 1 ORDER BY 1""",
            (code,),
        )
    )
    customer["top_items"] = clean(
        db.rows(
            """
        SELECT item_code, MAX(item_description) AS description, SUM(qty) AS qty, SUM(net) AS net_sales
        FROM sales_facts WHERE customer_code = ? AND item_code IS NOT NULL
        GROUP BY 1 ORDER BY 4 DESC LIMIT ?""",
            (code, limit_items),
        )
    )
    customer["repairs"] = db.rows(
        """SELECT COUNT(*) AS total, MIN(opened_on) AS first, MAX(opened_on) AS last
                                     FROM repairs WHERE customer_code = ?""",
        (code,),
    )[0]
    customer["recent_repairs"] = db.rows(
        """
        SELECT repair_id, opened_on, equipment_type, brand_name, model, status
        FROM repairs WHERE customer_code = ? ORDER BY opened_on DESC LIMIT 5""",
        (code,),
    )
    return customer


@tool("Valuable customers who stopped buying (win-back list).")
def dormant_customers(min_net: float = 500, inactive_days: int = 365, limit: LimitArg = 30) -> list[dict]:
    """Good customers (net sales >= min_net all-time) who haven't bought for `inactive_days`."""
    return clean(db.rows(f"""
        SELECT customer_code, MAX(customer_name) AS customer, SUM(net) AS net_sales, MAX(doc_date) AS last_purchase,
               CAST(julianday((SELECT MAX(doc_date) FROM sales_docs)) - julianday(MAX(doc_date)) AS INTEGER)
                 AS days_since
        FROM sales_facts WHERE {_NOT_WALK_IN}
        GROUP BY 1 HAVING SUM(net) >= ? AND days_since >= ? ORDER BY net_sales DESC LIMIT ?""",
                         (min_net, inactive_days, int(limit))))  # fmt: skip

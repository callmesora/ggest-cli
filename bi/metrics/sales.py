"""Sales tools: totals over time, KPIs, products, categories, growth, weekday/hour pattern."""

from typing import Literal

from .. import dates, db
from ..registry import DateArg, LimitArg, tool
from ._sql import clean, pick_one, rnd, where

PERIODS = {"year": "year", "quarter": "quarter", "month": "month", "day": "doc_date"}
WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
Period = Literal["year", "quarter", "month", "day"]


@tool("Net sales/margin/documents/customers per year, quarter, month or day.")
def sales_over_time(period: Period = "month", start: DateArg = None, end: DateArg = None) -> list[dict]:
    """Net sales, gross margin, margin %, invoices and distinct customers per period."""
    w, p = where(start, end)
    return clean(
        db.rows(
            f"""
        SELECT {PERIODS[period]} AS period, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0 * SUM(margin) / NULLIF(SUM(net), 0) AS margin_pct,
               COUNT(DISTINCT doc_id) AS documents, COUNT(DISTINCT customer_code) AS customers,
               SUM(CASE WHEN line_kind = 'product' THEN net END) AS products_net,
               SUM(CASE WHEN line_kind = 'service' THEN net END) AS services_net
        FROM sales_facts {w} GROUP BY 1 ORDER BY 1""",
            p,
        )
    )


@tool("Headline KPIs for a period (net sales, gross margin, invoices, customers, avg invoice, repairs).")
def kpis(start: DateArg = None, end: DateArg = None) -> dict:
    """Headline numbers for a period: sales, margin, invoices, customers, average ticket, repairs."""
    w, p = where(start, end)
    s = db.rows(
        f"""SELECT SUM(net) AS net_sales, SUM(margin) AS gross_margin,
                    100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct,
                    COUNT(DISTINCT CASE WHEN doc_class='invoice' THEN doc_id END) AS invoices,
                    COUNT(DISTINCT customer_code) AS customers,
                    SUM(CASE WHEN cost_source='estimated' THEN net END) AS net_with_estimated_cost
                    FROM sales_facts {w}""",
        p,
    )[0]
    s["avg_invoice_net"] = (s["net_sales"] or 0) / s["invoices"] if s["invoices"] else None
    w2, p2 = where(start, end, date_col="opened_on")
    s["repairs_opened"] = db.rows(f"SELECT COUNT(*) AS n FROM repairs {w2}", p2)[0]["n"]
    return {k: rnd(v) for k, v in s.items()}


@tool("Best-selling items by net sales, margin or quantity.")
def top_products(
    start: DateArg = None,
    end: DateArg = None,
    by: Literal["net", "margin", "qty"] = "net",
    limit: LimitArg = 20,
    kind: Literal["product", "service", "fee"] | None = None,
) -> list[dict]:
    """Best items by net sales, gross margin or quantity; kind filters product | service | fee lines."""
    order = {"net": "net_sales", "margin": "gross_margin", "qty": "qty"}[by]
    w, p = where(start, end, ["item_code IS NOT NULL"] + (["line_kind = ?"] if kind else []))
    p += [kind] if kind else []
    return clean(
        db.rows(
            f"""
        SELECT item_code,
               COALESCE((SELECT description FROM items i WHERE i.item_code = f.item_code), MAX(item_description))
                 AS description,
               MAX(family_name) AS family, MAX(brand_name) AS brand,
               SUM(qty) AS qty, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct, COUNT(DISTINCT customer_code) AS customers
        FROM sales_facts f {w} GROUP BY item_code ORDER BY {order} DESC LIMIT ?""",
            [*p, int(limit)],
        )
    )


@tool("Sales and margin by product group, family, brand or kind.")
def sales_by_category(
    level: Literal["group", "family", "brand", "kind"] = "family",
    start: DateArg = None,
    end: DateArg = None,
    limit: LimitArg = 30,
) -> list[dict]:
    """Net sales and margin by product group, family, brand or line kind (product/service/fee)."""
    col = {"group": "group_name", "family": "family_name", "brand": "brand_name", "kind": "line_kind"}[level]
    w, p = where(start, end)
    return clean(
        db.rows(
            f"""
        SELECT COALESCE({col}, '(none)') AS category, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct, SUM(qty) AS qty,
               100.0*SUM(net)/(SELECT SUM(net) FROM sales_facts {w}) AS share_pct
        FROM sales_facts {w} GROUP BY 1 ORDER BY net_sales DESC LIMIT ?""",
            [*p, *p, int(limit)],
        )
    )


def _same_days_last_year_growth(net_sales: float, words: dict) -> float | None:
    ly = db.rows("SELECT SUM(net) AS n FROM sales_facts WHERE doc_date BETWEEN ? AND ?",
                 (words["last_year_start"], words["today_last_year"]))[0]["n"]  # fmt: skip
    return round(100 * (net_sales / ly - 1), 1) if ly else None


def _with_growth(rows: list[dict]) -> list[dict]:
    """Add growth_pct vs the previous row (full years)."""
    prev = None
    for r in rows:
        r["growth_pct"] = round(100 * (r["net_sales"] / prev - 1), 1) if prev else None
        r["basis"] = "full year"
        prev = r["net_sales"]
    return rows


@tool("Annual net sales, margin and growth vs previous year (the partial current year vs the same days last year).")
def year_over_year(start_year: int | None = None, end_year: int | None = None) -> list[dict]:
    """Annual net sales, margin and growth vs the previous year."""
    lo, hi = start_year or 0, end_year or 9999
    rows = _with_growth([r for r in sales_over_time("year") if r["period"] and lo <= r["period"] <= hi])
    words = dates.date_words()
    last = rows[-1] if rows else None
    if last and last["period"] == words["this_year"] and words["today_mmdd"] != "12-31":
        # partial year: compare with the same days of the previous year, never with the full year
        last["growth_pct"] = _same_days_last_year_growth(last["net_sales"], words)
        last["basis"] = f"year to date (01-01..{words['today_mmdd']}) vs same days last year"
    return rows


@tool("Full profile of one item by code or part of the description.")
def product_profile(query: str) -> dict:
    """One item: catalogue data, sales per year, top customers."""
    matches = db.rows(
        """SELECT item_code, description, kind, family_name, brand_name, price_net, last_purchase_price,
                                last_supplier, stock_qty FROM items
                         WHERE item_code = ? OR lower(description) LIKE lower(?) LIMIT 10""",
        (query, f"%{query}%"),
    )
    item = pick_one(matches, "item_code", query, "item")
    if "item_code" not in item:
        return item
    code = item["item_code"]
    item["sales_by_year"] = clean(
        db.rows(
            """
        SELECT year, SUM(qty) AS qty, SUM(net) AS net_sales, SUM(margin) AS gross_margin
        FROM sales_facts WHERE item_code = ? GROUP BY 1 ORDER BY 1""",
            (code,),
        )
    )
    item["top_customers"] = clean(
        db.rows(
            """
        SELECT customer_code, MAX(customer_name) AS customer, SUM(qty) AS qty, SUM(net) AS net_sales
        FROM sales_facts WHERE item_code = ? GROUP BY 1 ORDER BY 4 DESC LIMIT 10""",
            (code,),
        )
    )
    return item


@tool("Invoices and sales by weekday and hour.")
def sales_by_weekday_hour(start: DateArg = None, end: DateArg = None) -> list[dict]:
    """When the shop sells: invoices and net sales by weekday and hour of day."""
    w, p = where(start, end, ["is_cancelled = 0", "is_internal = 0", "doc_class = 'invoice'"])
    rows = db.rows(
        f"""SELECT weekday, hour, COUNT(*) AS invoices, SUM(net) AS net_sales
                       FROM sales_docs {w} GROUP BY 1, 2 ORDER BY 1, 2""",
        p,
    )
    for r in rows:
        r["weekday_name"] = WEEKDAYS[r["weekday"]] if r["weekday"] is not None else None
    return clean(rows)

"""Business metrics for Inforbyte (computer shop: hardware sales, repairs, software/services).

Every function returns plain data (list of dicts / dict) and is registered in TOOLS with a JSON schema,
so the same functions power the CLI (`py -m bi ...`), the MCP server for AI agents and the dashboards.

Conventions (see docs/DATA_DICTIONARY.md):
  * money is NET of VAT, in EUR; credit notes are negative; cancelled docs and internal consumption excluded
  * margin = net - qty * unit_cost (gross margin estimate; unit_cost from average cost at sale time)
  * dates are ISO 'YYYY-MM-DD'; `start` inclusive, `end` inclusive; omit for all time
"""
from . import db

PERIODS = {"year": "year", "quarter": "quarter", "month": "month", "day": "doc_date"}
WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]


def _where(start=None, end=None, extra=None, date_col="doc_date"):
    conds, params = [], []
    if start:
        conds.append(f"{date_col} >= ?"); params.append(start)
    if end:
        conds.append(f"{date_col} <= ?"); params.append(end)
    if extra:
        conds.extend(extra)
    return ("WHERE " + " AND ".join(conds)) if conds else "", params


def _r(v, n=2):
    return round(v, n) if isinstance(v, float) else v


def _clean(rows):
    return [{k: _r(v) for k, v in r.items()} for r in rows]


# --- Sales -------------------------------------------------------------------------------------------

def sales_over_time(period="month", start=None, end=None):
    """Net sales, gross margin, margin %, invoices and distinct customers per period."""
    col = PERIODS[period]
    w, p = _where(start, end)
    return _clean(db.rows(f"""
        SELECT {col} AS period, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0 * SUM(margin) / NULLIF(SUM(net), 0) AS margin_pct,
               COUNT(DISTINCT doc_id) AS documents, COUNT(DISTINCT customer_code) AS customers,
               SUM(CASE WHEN line_kind = 'product' THEN net END) AS products_net,
               SUM(CASE WHEN line_kind = 'service' THEN net END) AS services_net
        FROM sales_facts {w} GROUP BY 1 ORDER BY 1""", p))


def kpis(start=None, end=None):
    """Headline numbers for a period: sales, margin, invoices, customers, average ticket, repairs."""
    w, p = _where(start, end)
    s = db.rows(f"""SELECT SUM(net) AS net_sales, SUM(margin) AS gross_margin,
                    100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct,
                    COUNT(DISTINCT CASE WHEN doc_class='invoice' THEN doc_id END) AS invoices,
                    COUNT(DISTINCT customer_code) AS customers,
                    SUM(CASE WHEN cost_source='estimated' THEN net END) AS net_with_estimated_cost
                    FROM sales_facts {w}""", p)[0]
    s["avg_invoice_net"] = (s["net_sales"] or 0) / s["invoices"] if s["invoices"] else None
    w2, p2 = _where(start, end, date_col="opened_on")
    s["repairs_opened"] = db.rows(f"SELECT COUNT(*) AS n FROM repairs {w2}", p2)[0]["n"]
    return {k: _r(v) for k, v in s.items()}


def top_products(start=None, end=None, by="net", limit=20, kind=None):
    """Best items by net sales, gross margin or quantity. kind: product | service | fee."""
    order = {"net": "net_sales", "margin": "gross_margin", "qty": "qty"}[by]
    extra = ["item_code IS NOT NULL"] + ([f"line_kind = '{kind}'"] if kind in ("product", "service", "fee") else [])
    w, p = _where(start, end, extra)
    return _clean(db.rows(f"""
        SELECT item_code, COALESCE((SELECT description FROM items i WHERE i.item_code = f.item_code), MAX(item_description)) AS description,
               MAX(family_name) AS family, MAX(brand_name) AS brand,
               SUM(qty) AS qty, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct, COUNT(DISTINCT customer_code) AS customers
        FROM sales_facts f {w} GROUP BY item_code ORDER BY {order} DESC LIMIT ?""", p + [int(limit)]))


def sales_by_category(level="family", start=None, end=None, limit=30):
    """Net sales and margin by product group, family, brand or line kind (product/service/fee)."""
    col = {"group": "group_name", "family": "family_name", "brand": "brand_name", "kind": "line_kind"}[level]
    w, p = _where(start, end)
    return _clean(db.rows(f"""
        SELECT COALESCE({col}, '(none)') AS category, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
               100.0*SUM(margin)/NULLIF(SUM(net),0) AS margin_pct, SUM(qty) AS qty,
               100.0*SUM(net)/(SELECT SUM(net) FROM sales_facts {w}) AS share_pct
        FROM sales_facts {w} GROUP BY 1 ORDER BY net_sales DESC LIMIT ?""", p + p + [int(limit)]))


def top_customers(start=None, end=None, by="net", limit=20, include_walk_in=False):
    """Customers ranked by net sales or margin, with invoices, first/last purchase and repairs count."""
    order = {"net": "net_sales", "margin": "gross_margin", "invoices": "invoices"}[by]
    extra = [] if include_walk_in else ["customer_code NOT IN (SELECT customer_code FROM customers WHERE is_walk_in = 1)"]
    w, p = _where(start, end, extra)
    return _clean(db.rows(f"""
        WITH s AS (
          SELECT customer_code, MAX(customer_name) AS customer, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
                 COUNT(DISTINCT doc_id) AS invoices, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase
          FROM sales_facts {w} GROUP BY customer_code)
        SELECT s.*, 100.0*gross_margin/NULLIF(net_sales,0) AS margin_pct,
               (SELECT COUNT(*) FROM repairs r WHERE r.customer_code = s.customer_code) AS repairs_all_time
        FROM s ORDER BY {order} DESC LIMIT ?""", p + [int(limit)]))


def customer_concentration(start=None, end=None):
    """How dependent sales are on top customers: share of net sales from top 10 / 20 / 50 / 100."""
    w, p = _where(start, end)
    rows = db.rows(f"SELECT customer_code, SUM(net) AS v FROM sales_facts {w} GROUP BY 1 ORDER BY v DESC", p)
    total = sum(r["v"] or 0 for r in rows) or 1
    out = {"customers": len(rows), "net_sales": round(total, 2)}
    for n in (1, 10, 20, 50, 100):
        out[f"top{n}_share_pct"] = round(100 * sum(r["v"] or 0 for r in rows[:n]) / total, 1)
    return out


def customer_profile(query, limit_items=15):
    """Everything about one customer (code or part of the name): totals per year, top items, repairs."""
    matches = db.rows("""SELECT customer_code, name, nif, email, phone, opened_on, is_walk_in FROM customers
                         WHERE customer_code = ? OR lower(name) LIKE lower(?) OR nif = ? LIMIT 10""",
                      (query, f"%{query}%", query))
    if not matches:
        return {"error": f"no customer matches {query!r}"}
    if len(matches) > 1 and not any(m["customer_code"] == query for m in matches):
        return {"ambiguous": matches}
    c = next((m for m in matches if m["customer_code"] == query), matches[0])
    code = c["customer_code"]
    c["sales_by_year"] = _clean(db.rows("""SELECT year, SUM(net) AS net_sales, SUM(margin) AS gross_margin,
                                           COUNT(DISTINCT doc_id) AS invoices FROM sales_facts
                                           WHERE customer_code = ? GROUP BY 1 ORDER BY 1""", (code,)))
    c["top_items"] = _clean(db.rows("""SELECT item_code, MAX(item_description) AS description, SUM(qty) AS qty,
                                       SUM(net) AS net_sales FROM sales_facts WHERE customer_code = ? AND item_code IS NOT NULL
                                       GROUP BY 1 ORDER BY 4 DESC LIMIT ?""", (code, limit_items)))
    c["repairs"] = db.rows("""SELECT COUNT(*) AS total, MIN(opened_on) AS first, MAX(opened_on) AS last
                              FROM repairs WHERE customer_code = ?""", (code,))[0]
    c["recent_repairs"] = db.rows("""SELECT repair_id, opened_on, equipment_type, brand_name, reported_fault, status
                                     FROM repairs WHERE customer_code = ? ORDER BY opened_on DESC LIMIT 5""", (code,))
    return c


def product_profile(query):
    """One item (code or part of the description): catalogue data, sales per year, top customers."""
    matches = db.rows("""SELECT item_code, description, kind, family_name, brand_name, price_net, last_purchase_price,
                                last_supplier, stock_qty FROM items
                         WHERE item_code = ? OR lower(description) LIKE lower(?) LIMIT 10""", (query, f"%{query}%"))
    if not matches:
        return {"error": f"no item matches {query!r}"}
    if len(matches) > 1 and not any(m["item_code"] == query for m in matches):
        return {"ambiguous": matches}
    it = next((m for m in matches if m["item_code"] == query), matches[0])
    code = it["item_code"]
    it["sales_by_year"] = _clean(db.rows("""SELECT year, SUM(qty) AS qty, SUM(net) AS net_sales, SUM(margin) AS gross_margin
                                            FROM sales_facts WHERE item_code = ? GROUP BY 1 ORDER BY 1""", (code,)))
    it["top_customers"] = _clean(db.rows("""SELECT customer_code, MAX(customer_name) AS customer, SUM(qty) AS qty,
                                            SUM(net) AS net_sales FROM sales_facts WHERE item_code = ?
                                            GROUP BY 1 ORDER BY 4 DESC LIMIT 10""", (code,)))
    return it


def sales_by_weekday_hour(start=None, end=None):
    """When the shop sells: invoices and net sales by weekday and hour of day."""
    w, p = _where(start, end, ["is_cancelled = 0", "is_internal = 0", "doc_class = 'invoice'"])
    rows = db.rows(f"""SELECT weekday, hour, COUNT(*) AS invoices, SUM(net) AS net_sales
                       FROM sales_docs {w} GROUP BY 1, 2 ORDER BY 1, 2""", p)
    for r in rows:
        r["weekday_name"] = WEEKDAYS[r["weekday"]] if r["weekday"] is not None else None
    return _clean(rows)


def year_over_year(start_year=None, end_year=None):
    """Annual net sales, margin and growth vs the previous year (current year is partial)."""
    rows = sales_over_time("year")
    rows = [r for r in rows if r["period"] and (start_year is None or r["period"] >= int(start_year))
            and (end_year is None or r["period"] <= int(end_year))]
    prev = None
    for r in rows:
        r["growth_pct"] = round(100 * (r["net_sales"] / prev - 1), 1) if prev else None
        prev = r["net_sales"]
    return rows


def dormant_customers(min_net=500, inactive_days=365, limit=30):
    """Good customers (net sales >= min_net all-time) who haven't bought for `inactive_days`."""
    return _clean(db.rows("""
        SELECT customer_code, MAX(customer_name) AS customer, SUM(net) AS net_sales, MAX(doc_date) AS last_purchase,
               CAST(julianday((SELECT MAX(doc_date) FROM sales_docs)) - julianday(MAX(doc_date)) AS INTEGER) AS days_since
        FROM sales_facts
        WHERE customer_code NOT IN (SELECT customer_code FROM customers WHERE is_walk_in = 1)
        GROUP BY 1 HAVING SUM(net) >= ? AND days_since >= ? ORDER BY net_sales DESC LIMIT ?""",
                          (min_net, inactive_days, int(limit))))


# --- Repairs (assistências) ----------------------------------------------------------------------------

def repairs_over_time(period="year", start=None, end=None):
    """Repair orders opened per period, with how many are still open."""
    col = {"year": "year", "month": "month"}[period]
    w, p = _where(start, end, date_col="opened_on")
    return db.rows(f"""SELECT {col} AS period, COUNT(*) AS repairs,
                       SUM(status_code NOT IN ('FEC')) AS not_closed, COUNT(DISTINCT customer_code) AS customers
                       FROM repairs {w} GROUP BY 1 ORDER BY 1""", p)


def repairs_breakdown(by="equipment", start=None, end=None, limit=25):
    """Repairs by equipment type, brand, technician or status."""
    col = {"equipment": "COALESCE(equipment_type, equipment_type_code)", "brand": "COALESCE(brand_name, brand_code)",
           "technician": "COALESCE((SELECT t.descricao FROM assTec_tecnicos t WHERE t.codigo = repairs.repair_technician_code), repair_technician_code, '(não registado)')", "status": "COALESCE(status, status_code)"}[by]
    w, p = _where(start, end, date_col="opened_on")
    return db.rows(f"""SELECT {col} AS category, COUNT(*) AS repairs,
                       100.0 * COUNT(*) / (SELECT COUNT(*) FROM repairs {w}) AS share_pct
                       FROM repairs {w} GROUP BY 1 ORDER BY 2 DESC LIMIT ?""", p + p + [int(limit)])


def repair_turnaround(start=None, end=None):
    """Days from opening to closing a repair (closed repairs with a real closing date), per year."""
    w, p = _where(start, end, ["closed_at IS NOT NULL", "closed_at >= opened_on"], date_col="opened_on")
    return _clean(db.rows(f"""
        SELECT year, COUNT(*) AS closed_repairs, AVG(julianday(closed_at) - julianday(opened_on)) AS avg_days,
               SUM(julianday(closed_at) - julianday(opened_on) <= 1) AS within_1_day,
               SUM(julianday(closed_at) - julianday(opened_on) <= 7) AS within_7_days
        FROM repairs {w} GROUP BY 1 ORDER BY 1""", p))


def repair_revenue(period="year", start=None, end=None):
    """Service revenue (labour/assistance lines) on invoices, vs number of repairs opened."""
    col = PERIODS[period]
    w, p = _where(start, end, ["line_kind = 'service'"])
    svc = db.rows(f"""SELECT {col} AS period, SUM(net) AS service_net,
                      SUM(CASE WHEN origin_doc_type = 'OSA' THEN net END) AS billed_from_repair_orders
                      FROM sales_facts {w} GROUP BY 1 ORDER BY 1""", p)
    rep = {r["period"]: r["repairs"] for r in repairs_over_time("year" if period == "year" else "month", start, end)}
    for r in svc:
        r["repairs_opened"] = rep.get(r["period"])
    return _clean(svc)


def common_faults(limit=30, start=None, end=None):
    """Most frequent reported faults (normalised text), to see what breaks most."""
    w, p = _where(start, end, ["reported_fault IS NOT NULL", "trim(reported_fault) <> ''"], date_col="opened_on")
    return db.rows(f"""SELECT lower(trim(reported_fault)) AS fault, COUNT(*) AS repairs FROM repairs {w}
                       GROUP BY 1 ORDER BY 2 DESC LIMIT ?""", p + [int(limit)])


# --- Purchases ----------------------------------------------------------------------------------------

def purchases_by_supplier(start=None, end=None, limit=20):
    """Net purchases per supplier (credit notes negative, cancelled excluded)."""
    w, p = _where(start, end, ["is_cancelled = 0"])
    return _clean(db.rows(f"""SELECT supplier_code, MAX(supplier_name) AS supplier, SUM(net) AS net_purchases,
                              COUNT(*) AS documents, MAX(doc_date) AS last_purchase
                              FROM purchase_docs {w} GROUP BY 1 ORDER BY 3 DESC LIMIT ?""", p + [int(limit)]))


def purchases_vs_sales(period="year", start=None, end=None):
    """Purchases vs sales per period (cash view of stock investment)."""
    col = {"year": "year", "month": "month"}[period]
    w, p = _where(start, end, ["is_cancelled = 0"])
    pur = {r["period"]: r["v"] for r in db.rows(f"SELECT {col} AS period, SUM(net) AS v FROM purchase_docs {w} GROUP BY 1", p)}
    out = sales_over_time(period, start, end)
    for r in out:
        r["net_purchases"] = _r(pur.get(r["period"]))
    return out


# --- Data access for agents ------------------------------------------------------------------------

def describe(name=None):
    """List business views (or one view's columns). Prefer these over raw gGest tables."""
    if not name:
        return db.rows("SELECT name, type FROM sqlite_master WHERE type='view' ORDER BY name")
    if db._SECRET.search(name):
        return {"error": f"{name} holds passwords and is not available through this tool"}
    cols = db.rows(f"SELECT name, type FROM pragma_table_info(?)", (name,))
    sample = db.rows(f'SELECT * FROM "{name}" LIMIT 3') if cols else []
    return {"name": name, "columns": cols, "sample": sample}


def query(sql, limit=200):
    """Read-only SQL (one SELECT/WITH) over business views and raw tables. Max `limit` rows."""
    return db.safe_query(sql, int(limit))


# --- Registry used by the CLI and the MCP server ---------------------------------------------------------

_D = {"type": "string", "description": "ISO date YYYY-MM-DD (inclusive); omit for all time"}
TOOLS = {
    "kpis": (kpis, "Headline KPIs for a period (net sales, gross margin, invoices, customers, avg invoice, repairs).",
             {"start": _D, "end": _D}),
    "sales_over_time": (sales_over_time, "Net sales/margin/documents/customers per year, quarter, month or day.",
                        {"period": {"type": "string", "enum": list(PERIODS)}, "start": _D, "end": _D}),
    "year_over_year": (year_over_year, "Annual net sales, margin and growth vs previous year.",
                       {"start_year": {"type": "integer"}, "end_year": {"type": "integer"}}),
    "top_products": (top_products, "Best-selling items by net sales, margin or quantity.",
                     {"start": _D, "end": _D, "by": {"type": "string", "enum": ["net", "margin", "qty"]},
                      "limit": {"type": "integer"}, "kind": {"type": "string", "enum": ["product", "service", "fee"]}}),
    "sales_by_category": (sales_by_category, "Sales and margin by product group, family, brand or kind.",
                          {"level": {"type": "string", "enum": ["group", "family", "brand", "kind"]},
                           "start": _D, "end": _D, "limit": {"type": "integer"}}),
    "top_customers": (top_customers, "Customers ranked by net sales, margin or number of invoices.",
                      {"start": _D, "end": _D, "by": {"type": "string", "enum": ["net", "margin", "invoices"]},
                       "limit": {"type": "integer"}, "include_walk_in": {"type": "boolean"}}),
    "customer_concentration": (customer_concentration, "Share of sales from the top 1/10/20/50/100 customers.",
                               {"start": _D, "end": _D}),
    "customer_profile": (customer_profile, "Full profile of one customer by code, NIF or part of the name.",
                         {"query": {"type": "string"}}),
    "product_profile": (product_profile, "Full profile of one item by code or part of the description.",
                        {"query": {"type": "string"}}),
    "dormant_customers": (dormant_customers, "Valuable customers who stopped buying (win-back list).",
                          {"min_net": {"type": "number"}, "inactive_days": {"type": "integer"}, "limit": {"type": "integer"}}),
    "sales_by_weekday_hour": (sales_by_weekday_hour, "Invoices and sales by weekday and hour.", {"start": _D, "end": _D}),
    "repairs_over_time": (repairs_over_time, "Repair orders (assistências) opened per year or month.",
                          {"period": {"type": "string", "enum": ["year", "month"]}, "start": _D, "end": _D}),
    "repairs_breakdown": (repairs_breakdown, "Repairs by equipment type, brand, technician or status.",
                          {"by": {"type": "string", "enum": ["equipment", "brand", "technician", "status"]},
                           "start": _D, "end": _D, "limit": {"type": "integer"}}),
    "repair_turnaround": (repair_turnaround, "Days to close repairs, per year.", {"start": _D, "end": _D}),
    "repair_revenue": (repair_revenue, "Service (labour) revenue vs repairs opened.",
                       {"period": {"type": "string", "enum": ["year", "quarter", "month"]}, "start": _D, "end": _D}),
    "common_faults": (common_faults, "Most frequent reported faults.", {"limit": {"type": "integer"}, "start": _D, "end": _D}),
    "purchases_by_supplier": (purchases_by_supplier, "Net purchases per supplier.",
                              {"start": _D, "end": _D, "limit": {"type": "integer"}}),
    "purchases_vs_sales": (purchases_vs_sales, "Purchases vs sales per year or month.",
                           {"period": {"type": "string", "enum": ["year", "month"]}, "start": _D, "end": _D}),
    "describe": (describe, "List business views, or columns + sample rows of one view/table.",
                 {"name": {"type": "string"}}),
    "query": (query, "Read-only SQL (single SELECT/WITH) for questions the other tools don't cover. "
                     "Use business views (sales_facts, sales_docs, customers, items, repairs, purchase_docs).",
              {"sql": {"type": "string"}, "limit": {"type": "integer"}}),
}
from . import saved as _saved  # noqa: E402
TOOLS["saved_queries"] = (_saved.saved_queries, "List the saved-query library (reusable, documented SQL by domain).",
                          {"domain": {"type": "string"}})
TOOLS["run_saved_query"] = (_saved.run_saved_query, "Run a saved query by name; params override its defaults.",
                            {"name": {"type": "string"}, "params": {"type": "object"}, "limit": {"type": "integer"}})
REQUIRED = {"customer_profile": ["query"], "product_profile": ["query"], "query": ["sql"], "run_saved_query": ["name"]}

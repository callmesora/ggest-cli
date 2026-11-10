"""Third batch of dashboard datasets: year-to-date gap by business line, overheads by category, Chip7 vs shop,
business mix over time, labour price, action lists (replacement leads, dead stock, low-margin items, open repairs),
days to pay, sales per person, data quality. Listed in :data:`DATASETS`, exported by export_datasets.py.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from dashboards.common import Context, Dataset, Row, clean_rows, pivot_sum, sorted_values
from dashboards.common import run_saved as run

OVERHEAD_GROUPS = {
    "01": "staff",
    "02": "rent",
    "06": "franchise",
    "03": "vehicles",
    "05": "services",
    "07": "services",
    "08": "services",
    "04": "other",
    "09": "other",
    "13": "other",
}
# 10-12 (taxes, investment, loans) are not operating costs and are left out
OVERHEAD_COLUMNS = ("staff", "rent", "franchise", "vehicles", "services", "other")
LINE_GROUPS = {
    "Computadores e tablets": "computers",
    "Perifericos, monitores e impressoras": "peripherals",
    "Componentes, pecas e armazenamento": "components",
    "Consumiveis": "consumables",
    "Assistencia tecnica e servicos": "services",
    "gGest - licencas e modulos": "software",
    "gGest - contratos anuais de actualizacao": "software",
    "gGest - subscricoes anuais/cloud": "software",
    "Servico fecho/abertura de ano": "software",
}
LINE_COLUMNS = ("computers", "peripherals", "components", "consumables", "services", "software", "other")
TOP_USERS = 2

LABOUR_COLUMNS = ["year", "repairs", "labour_net", "labour_invoices", "labour_per_invoice", "orders_with_value_pct"]
LEAD_COLUMNS = [
    "repair_id",
    "opened_on",
    "customer_name",
    "equipment",
    "brand",
    "lead_reason",
    "device_repairs",
    "net_bought_last_3y",
]
DEAD_STOCK_COLUMNS = [
    "item_code",
    "description",
    "group_name",
    "qty",
    "stock_value",
    "last_sale",
    "days_without_movement",
]
LOW_MARGIN_COLUMNS = ["item_code", "description", "brand_name", "qty", "net_sales", "gross_margin", "margin_pct"]
OPEN_REPAIR_COLUMNS = ["repair_id", "opened_on", "age_days", "status", "equipment_type", "customer_name", "order_net"]
DAYS_TO_PAY_COLUMNS = ["year", "invoices", "weighted_avg_days", "avg_days", "pct_within_30d", "pct_over_60d"]


def ytd_by_line(ctx: Context) -> list[Row]:
    """Year to date vs the same period last year, per business line (top 10)."""
    params = {
        "a_start": f"{ctx.ly}-01-01",
        "a_end": f"{ctx.ly}-{ctx.md}",
        "b_start": f"{ctx.this_year}-01-01",
        "b_end": f"{ctx.this_year}-{ctx.md}",
    }
    return clean_rows(run("sales_period_comparison_by_line", params)[:10])


def overheads_yearly(_ctx: Context) -> list[Row]:
    """Operating expenses per category group and year (from 2021)."""
    rows = run("finance_operating_expenses_by_category", {"start_year": 2021}, limit=1000)
    return pivot_sum(rows, "year", OVERHEAD_COLUMNS, lambda r: OVERHEAD_GROUPS.get(r["category"][:2]), value="net")


def chip7_vs_shop(_ctx: Context) -> list[Row]:
    """Series groups from the config (Inforbyte: Chip7 corner vs the shop), pivoted to the dashboard's columns."""
    table: dict[int, Row] = {}
    for r in run("sales_series_groups_by_year", {"start_year": 2022}):
        row = table.setdefault(r["year"], {"year": r["year"]})
        k = "shop" if r["series_group"] == "Loja" else "chip7"
        row[f"{k}_net"], row[f"{k}_margin_pct"] = r["net"], r["margin_pct"]
        if k == "chip7":
            row.update(chip7_margin=r["margin"], chip7_documents=r["documents"], chip7_share_pct=r["share_pct"])
    return sorted_values(table)


def lines_by_year(_ctx: Context) -> list[Row]:
    """Net sales per business-line group and year."""
    rows = run("sales_business_lines_by_year", limit=1000)
    return pivot_sum(rows, "year", LINE_COLUMNS, lambda r: LINE_GROUPS.get(r["business_line"], "other"))


def top_user_columns(rows: list[Mapping[str, Any]], n: int = TOP_USERS) -> dict[str, str]:
    """Map the ``n`` users with the most net sales to a column name (first name, lowercased)."""
    tot: dict[str, float] = {}
    for r in rows:
        tot[r["user_name"]] = tot.get(r["user_name"], 0) + (r["net_sales"] or 0)
    return {u: (u.split() or ["user"])[0].lower() for u in sorted(tot, key=tot.__getitem__, reverse=True)[:n]}


def sales_by_user(ctx: Context) -> list[Row]:
    """Net sales per year: one column per top-2 user, everyone else in 'others'."""
    rows = run("management_sales_by_user", {"start_year": 2022, "end_year": ctx.this_year})
    top = top_user_columns(rows)
    return pivot_sum(rows, "year", [*top.values(), "others"], lambda r: top.get(r["user_name"], "others"))


def data_quality(_ctx: Context) -> list[Row]:
    """Share of generic 'ZZ' items and of sales with an estimated cost, per year."""
    return [
        {
            "year": r["year"],
            "zz_share_pct": r["zz_share_pct"],
            "estimated_cost_pct": round(100 * (r["net_with_estimated_cost"] or 0) / r["net_sales"], 2)
            if r["net_sales"]
            else None,
            "zz_generic_net": r["zz_generic_net"],
            "zz_lines": r["zz_lines"],
        }
        for r in run("sales_data_quality_by_year")
    ]


DATASETS: list[Dataset] = [
    Dataset("ytd_by_line", "Year-to-date gap by business line", ytd_by_line),
    Dataset("overheads_yearly", "Overheads by category", overheads_yearly),
    Dataset("chip7_vs_shop", "Chip7 corner vs the shop", chip7_vs_shop),
    Dataset("lines_by_year", "Business mix over time", lines_by_year),
    Dataset(
        "labour_yearly",
        "Labour revenue and price",
        lambda _c: clean_rows(run("repairs_revenue_by_year"), LABOUR_COLUMNS),
    ),
    Dataset(
        "replacement_leads",
        "Repairs that could become an equipment sale",
        lambda _c: clean_rows(run("repairs_replacement_leads", {"limit": 25}), LEAD_COLUMNS),
    ),
    Dataset(
        "dead_stock",
        "Stock without movement",
        lambda c: clean_rows(
            run("finance_dead_stock_items", {"as_of": c.cut.isoformat(), "limit": 25}), DEAD_STOCK_COLUMNS
        ),
    ),
    Dataset(
        "low_margin_items",
        "Low-margin items, last 3 years",
        lambda c: clean_rows(run("sales_low_margin_items", {"start": c.last3, "limit": 20}), LOW_MARGIN_COLUMNS),
    ),
    Dataset(
        "open_repairs",
        "Oldest open repairs",
        lambda c: clean_rows(run("repairs_open_backlog", {"as_of": c.cut.isoformat()})[:30], OPEN_REPAIR_COLUMNS),
    ),
    Dataset(
        "days_to_pay",
        "Days to pay per year",
        lambda _c: clean_rows(run("finance_days_to_pay_by_year"), DAYS_TO_PAY_COLUMNS),
    ),
    Dataset("sales_by_user", "Sales per person", sales_by_user),
    Dataset("data_quality", "Data quality per year", data_quality),
]

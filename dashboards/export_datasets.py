"""Export the aggregated datasets behind the Inforbyte BI dashboard (JSON, one file per dataset).

Run from the project folder:  uv run python dashboards/export_datasets.py [--out <folder>]
Output: dashboards/datasets/<name>.json (+ _meta.json) — aggregates only (plus top-customer names), no raw records.

This module holds the core datasets and the single entry point; the other dataset groups live in key_facts.py,
more_datasets.py and more_datasets2.py and are listed in :data:`ALL_DATASETS`.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import db, metrics
from dashboards import key_facts, more_datasets, more_datasets2
from dashboards.common import Context, Dataset, Row, pick, pivot_sum, run_saved, save_dataset, write_json

DEFAULT_OUT = Path(__file__).resolve().parent / "datasets"

PNL_COLUMNS = (
    "year",
    "net_sales",
    "gross_margin",
    "gross_margin_pct",
    "staff_costs",
    "rents",
    "other_overheads",
    "total_overheads",
    "operating_result_indicative",
    "operating_margin_pct",
)
SEGMENT_COLUMNS = ("particular", "empresa", "publico", "associativo")
STREAMS = {
    "gGest contrato anual actualizacao": "contracts",
    "gGest subscricao anual/cloud": "subscriptions",
    "Servico fecho/abertura de ano": "year_end",
    "Alojamento e dominios": "hosting",
    "gGest licenca vitalicia (NAO recorrente)": "lifetime",
}
RECURRING_COLUMNS = ("contracts", "subscriptions", "year_end", "hosting", "other", "lifetime", "contract_customers")
RECURRING_IN_TOTAL = ("contracts", "subscriptions", "year_end", "hosting", "other")

NEW_CUSTOMERS_SQL = """
    WITH first AS (SELECT customer_code, MIN(year) AS y FROM sales_facts
                   WHERE customer_code NOT IN (SELECT customer_code FROM customers WHERE is_walk_in = 1) GROUP BY 1)
    SELECT f.year AS year, COUNT(DISTINCT f.customer_code) AS active_customers,
           COUNT(DISTINCT CASE WHEN first.y = f.year THEN f.customer_code END) AS new_customers
    FROM sales_facts f JOIN first USING (customer_code) GROUP BY 1 ORDER BY 1"""


def ytd_comparison(ctx: Context) -> list[Row]:
    """KPIs year to date vs the same days last year."""
    periods = (
        ("current", ctx.this_year, f"{ctx.this_year}-01-01", ctx.last),
        ("previous", ctx.ly, f"{ctx.ly}-01-01", f"{ctx.ly}-{ctx.md}"),
    )
    return [
        {"which": which, "period": f"{year} até {ctx.cut:%d/%m}", "start": s, "end": e, **metrics.kpis(s, e)}
        for which, year, s, e in periods
    ]


def repairs_yearly(_ctx: Context) -> list[Row]:
    """Repairs, customers and service revenue per year."""
    rep = {r["period"]: r for r in metrics.repairs_over_time("year")}
    svc = {r["period"]: r for r in metrics.repair_revenue("year")}
    return [
        {
            "year": y,
            "repairs": rep[y]["repairs"],
            "customers": rep[y]["customers"],
            "service_net": (svc.get(y) or {}).get("service_net"),
        }
        for y in sorted(rep)
        if y
    ]


def forecast(ctx: Context) -> list[Row]:
    """Year-end forecast from the share of the year usually sold by the cut-off date."""
    params = {"year": ctx.this_year, "cutoff": ctx.md, "ref_from": ctx.this_year - 4, "ref_to": ctx.this_year - 2}
    return run_saved("management_year_end_forecast", params)


def segment_column(r: Row) -> str:
    """Dashboard column for a customer segment (final consumers are shown as 'particular')."""
    return "particular" if r["segment"] == "consumidor_final" else r["segment"]


def segments_yearly(_ctx: Context) -> list[Row]:
    """Net sales per customer segment and year."""
    return pivot_sum(run_saved("customers_segment_by_year"), "year", SEGMENT_COLUMNS, segment_column)


def recurring_yearly(_ctx: Context) -> list[Row]:
    """Recurring revenue streams per year, contract customers and the recurring total (lifetime licences excluded)."""
    rows = run_saved("sales_recurring_revenue_by_year")
    table = pivot_sum(rows, "year", RECURRING_COLUMNS, lambda r: STREAMS.get(r["stream"], "other"))
    contract_customers = {r["year"]: r["customers"] for r in rows if STREAMS.get(r["stream"]) == "contracts"}
    for row in table:
        if row["year"] in contract_customers:
            row["contract_customers"] = contract_customers[row["year"]]
        row["recurring_total"] = round(sum(row[k] for k in RECURRING_IN_TOTAL), 2)
    return table


def stock_by_group(_ctx: Context) -> list[Row]:
    """Stock value of the 12 largest product groups."""
    return [r for r in run_saved("finance_stock_value_by_group") if r["group_name"] != "TOTAL"][:12]


def stock_total(_ctx: Context) -> list[Row]:
    """Total stock value row."""
    return [r for r in run_saved("finance_stock_value_by_group") if r["group_name"] == "TOTAL"]


CORE_DATASETS: list[Dataset] = [
    Dataset("sales_yearly", "Sales per year (current year partial)", lambda _c: metrics.year_over_year()),
    Dataset(
        "sales_monthly",
        "Sales per month since 2017",
        lambda _c: [r for r in metrics.sales_over_time("month") if r["period"] >= "2017-01"],
    ),
    Dataset("ytd_comparison", "Year to date vs same days last year", ytd_comparison),
    Dataset(
        "families_3y",
        "Top families, last 3 years",
        lambda c: metrics.sales_by_category("family", start=c.last3, limit=15),
    ),
    Dataset(
        "groups_3y", "Top groups, last 3 years", lambda c: metrics.sales_by_category("group", start=c.last3, limit=12)
    ),
    Dataset(
        "top_products_3y",
        "Top products by net sales",
        lambda c: metrics.top_products(start=c.last3, by="net", limit=15),
    ),
    Dataset(
        "top_margin_products_3y",
        "Top products by margin",
        lambda c: metrics.top_products(start=c.last3, by="margin", limit=15),
    ),
    Dataset("top_customers_all", "Top customers, all time", lambda _c: metrics.top_customers(by="net", limit=15)),
    Dataset("concentration_3y", "Customer concentration", lambda c: [metrics.customer_concentration(start=c.last3)]),
    Dataset(
        "dormant_customers",
        "Good customers gone quiet",
        lambda _c: metrics.dormant_customers(min_net=1000, inactive_days=365, limit=15),
    ),
    Dataset("new_customers_yearly", "Active and new customers per year", lambda _c: db.rows(NEW_CUSTOMERS_SQL)),
    Dataset("repairs_yearly", "Repairs per year", repairs_yearly),
    Dataset(
        "repairs_equipment_3y",
        "Repairs by equipment type",
        lambda c: metrics.repairs_breakdown("equipment", start=c.last3, limit=10),
    ),
    Dataset(
        "repairs_brand_3y", "Repairs by brand", lambda c: metrics.repairs_breakdown("brand", start=c.last3, limit=10)
    ),
    Dataset(
        "weekday_hour_3y",
        "When the shop sells (hour 0 = time not recorded, dropped)",
        lambda c: [r for r in metrics.sales_by_weekday_hour(start=c.last3) if r["hour"]],
    ),
    Dataset(
        "purchases_vs_sales",
        "Purchases vs sales per year",
        lambda _c: metrics.purchases_vs_sales("year", start="2017-01-01"),
    ),
    Dataset("top_suppliers_3y", "Top suppliers", lambda c: metrics.purchases_by_supplier(start=c.last3, limit=12)),
    Dataset(
        "pnl_yearly",
        "Indicative profit and loss per year",
        lambda _c: pick(run_saved("finance_profit_and_loss_by_year"), PNL_COLUMNS),
    ),
    Dataset("forecast", "Year-end forecast", forecast),
    Dataset(
        "business_lines_3y",
        "Business lines, last 3 complete years",
        lambda c: run_saved("sales_business_lines", {"start": c.last3, "end": f"{c.ly}-12-31"})[:12],
    ),
    Dataset("segments_yearly", "Customer segments per year", segments_yearly),
    Dataset("recurring_yearly", "Recurring revenue per year", recurring_yearly),
    Dataset(
        "receivables_aging",
        "Receivables by age bucket",
        lambda _c: [r for r in run_saved("finance_receivables_aging") if r["bucket"][:1].isdigit()],
    ),
    Dataset("stock_by_group", "Stock value by group", stock_by_group),
    Dataset("stock_total", "Total stock value", stock_total),
]

ALL_DATASETS: list[Dataset] = [
    *CORE_DATASETS,
    Dataset("key_facts", "Key facts quoted in the summary tab", lambda c: key_facts.key_facts(c.this_year, c.cut)),
    *more_datasets.DATASETS,
    *more_datasets2.DATASETS,
]


def meta(ctx: Context) -> dict[str, Any]:
    """Contents of _meta.json (export date is the local calendar date)."""
    exported_at = datetime.now().astimezone().date().isoformat()
    return {"exported_at": exported_at, "data_until": ctx.last, "this_year": ctx.this_year, "last3_from": ctx.last3}


def export_all(
    out_dir: Path = DEFAULT_OUT, ctx: Context | None = None, datasets: list[Dataset] | None = None
) -> Context:
    """Build every dataset, write ``<out_dir>/<name>.json`` plus ``_meta.json`` and return the context used."""
    ctx = ctx or Context.load()
    out_dir.mkdir(parents=True, exist_ok=True)
    for ds in ALL_DATASETS if datasets is None else datasets:
        save_dataset(out_dir, ds.name, ds.build(ctx))
    write_json(out_dir / "_meta.json", meta(ctx), indent=1)
    print("data until", ctx.last)
    return ctx


def main(argv: list[str] | None = None) -> int:
    """Command line entry point."""
    parser = argparse.ArgumentParser(description="Export the dashboard datasets (JSON).")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"output folder (default: {DEFAULT_OUT})")
    export_all(parser.parse_args(argv).out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

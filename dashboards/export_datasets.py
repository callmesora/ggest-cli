"""Export the aggregated datasets behind the Inforbyte BI dashboard (JSON, one file per dataset).

Run from the inforbyte-bi folder:  py dashboards/export_datasets.py
Output: dashboards/datasets/<name>.json  — aggregates only (plus top-customer names), no raw records.
"""
import json
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import db, metrics, saved  # noqa: E402

OUT = Path(__file__).resolve().parent / "datasets"
OUT.mkdir(exist_ok=True)

last = db.rows("SELECT MAX(doc_date) AS d FROM sales_docs WHERE is_cancelled = 0")[0]["d"]   # export cut-off
cut = date.fromisoformat(last)
this_year, prev_year = cut.year, cut.year - 1
ytd_prev_end = f"{prev_year}-{cut:%m-%d}"
last3 = f"{this_year - 3}-01-01"


def save(name, rows):
    (OUT / f"{name}.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    print(f"{name:22} {len(rows) if isinstance(rows, list) else 1} rows")


# Sales per year (current year partial) and per month
save("sales_yearly", metrics.year_over_year())
save("sales_monthly", [r for r in metrics.sales_over_time("month") if r["period"] >= "2017-01"])

# Year to date vs same days last year
ytd = []
for which, label, s, e in (("current", f"{this_year} até {cut:%d/%m}", f"{this_year}-01-01", last),
                           ("previous", f"{prev_year} até {cut:%d/%m}", f"{prev_year}-01-01", ytd_prev_end)):
    k = metrics.kpis(s, e)
    ytd.append({"which": which, "period": label, "start": s, "end": e, **k})
save("ytd_comparison", ytd)

# Product mix
save("families_3y", metrics.sales_by_category("family", start=last3, limit=15))
save("groups_3y", metrics.sales_by_category("group", start=last3, limit=12))
save("top_products_3y", metrics.top_products(start=last3, by="net", limit=15))
save("top_margin_products_3y", metrics.top_products(start=last3, by="margin", limit=15))

# Customers
save("top_customers_all", metrics.top_customers(by="net", limit=15))
save("concentration_3y", [metrics.customer_concentration(start=last3)])
save("dormant_customers", metrics.dormant_customers(min_net=1000, inactive_days=365, limit=15))
save("new_customers_yearly", db.rows("""
    WITH first AS (SELECT customer_code, MIN(year) AS y FROM sales_facts
                   WHERE customer_code NOT IN (SELECT customer_code FROM customers WHERE is_walk_in = 1) GROUP BY 1)
    SELECT f.year AS year, COUNT(DISTINCT f.customer_code) AS active_customers,
           COUNT(DISTINCT CASE WHEN first.y = f.year THEN f.customer_code END) AS new_customers
    FROM sales_facts f JOIN first USING (customer_code) GROUP BY 1 ORDER BY 1"""))

# Repairs
rep = {r["period"]: r for r in metrics.repairs_over_time("year")}
svc = {r["period"]: r for r in metrics.repair_revenue("year")}
save("repairs_yearly", [{"year": y, "repairs": rep[y]["repairs"], "customers": rep[y]["customers"],
                         "service_net": (svc.get(y) or {}).get("service_net")} for y in sorted(rep) if y])
save("repairs_equipment_3y", metrics.repairs_breakdown("equipment", start=last3, limit=10))
save("repairs_brand_3y", metrics.repairs_breakdown("brand", start=last3, limit=10))

# When the shop sells
save("weekday_hour_3y", [r for r in metrics.sales_by_weekday_hour(start=last3) if r["hour"]])  # hour 0 = time not recorded

# Purchases vs sales and suppliers
save("purchases_vs_sales", metrics.purchases_vs_sales("year", start="2017-01-01"))
save("top_suppliers_3y", metrics.purchases_by_supplier(start=last3, limit=12))

# Profit and loss, forecast, business lines, segments, recurring revenue, receivables, stock (saved queries)
run = saved.run_saved_query
save("pnl_yearly", [{k: r[k] for k in ("year", "net_sales", "gross_margin", "gross_margin_pct", "staff_costs", "rents",
                                        "other_overheads", "total_overheads", "operating_result_indicative",
                                        "operating_margin_pct")} for r in run("finance_profit_and_loss_by_year")])
save("forecast", run("management_year_end_forecast", {"year": this_year, "cutoff": f"{cut:%m-%d}",
                                                      "ref_from": this_year - 4, "ref_to": this_year - 2}))
save("business_lines_3y", run("sales_business_lines", {"start": f"{this_year - 3}-01-01", "end": f"{this_year - 1}-12-31"})[:12])
seg = {}
for r in run("customers_segment_by_year"):
    row = seg.setdefault(r["year"], {"year": r["year"], "particular": 0, "empresa": 0, "publico": 0, "associativo": 0})
    key = "particular" if r["segment"] == "consumidor_final" else r["segment"]
    row[key] = round(row.get(key, 0) + (r["net_sales"] or 0), 2)
save("segments_yearly", [seg[y] for y in sorted(seg)])
STREAMS = {"gGest contrato anual actualizacao": "contracts", "gGest subscricao anual/cloud": "subscriptions",
           "Servico fecho/abertura de ano": "year_end", "Alojamento e dominios": "hosting",
           "gGest licenca vitalicia (NAO recorrente)": "lifetime"}
rec = {}
for r in run("sales_recurring_revenue_by_year"):
    row = rec.setdefault(r["year"], {"year": r["year"], "contracts": 0, "subscriptions": 0, "year_end": 0, "hosting": 0,
                                     "other": 0, "lifetime": 0, "contract_customers": 0})
    k = STREAMS.get(r["stream"], "other")
    row[k] = round(row[k] + (r["net_sales"] or 0), 2)
    if k == "contracts":
        row["contract_customers"] = r["customers"]
for row in rec.values():
    row["recurring_total"] = round(sum(row[k] for k in ("contracts", "subscriptions", "year_end", "hosting", "other")), 2)
save("recurring_yearly", [rec[y] for y in sorted(rec)])
aging = run("finance_receivables_aging")
save("receivables_aging", [r for r in aging if r["bucket"][:1].isdigit()])
stock = run("finance_stock_value_by_group")
save("stock_by_group", [r for r in stock if r["group_name"] != "TOTAL"][:12])
save("stock_total", [r for r in stock if r["group_name"] == "TOTAL"])

# Key facts quoted in the summary tab
sys.path.insert(0, str(Path(__file__).resolve().parent))
from key_facts import key_facts  # noqa: E402
save("key_facts", key_facts(this_year, cut))

# Extra views (seasonality, invoice sizes, big deals, RFM, geography, repairs mix, payments, freight...)
from more_datasets import build as build_more  # noqa: E402
build_more(save, this_year)
from more_datasets2 import build as build_more2  # noqa: E402
build_more2(save, this_year, cut)

(OUT / "_meta.json").write_text(json.dumps({"exported_at": date.today().isoformat(), "data_until": last,
                                            "this_year": this_year, "last3_from": last3}, indent=1), encoding="utf-8")
print("data until", last)

"""Third batch of dashboard datasets: 2026 gap by business line, overheads by category, Chip7 vs shop, business mix
over time, labour price, action lists (replacement leads, dead stock, low-margin items, open repairs), days to pay,
sales per person, data quality. Called by export_datasets.py."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import saved  # noqa: E402


def clean(v):
    """Drop characters that can't be written as UTF-8 (a few gGest names hold broken bytes)."""
    if isinstance(v, str):
        return v.encode("utf-8", "replace").decode("utf-8").replace("�", "")
    return v


def rows(rs, keys=None):
    return [{k: clean(r[k]) for k in (keys or r.keys())} for r in rs]


OVERHEAD_GROUPS = {"01": "staff", "02": "rent", "06": "franchise", "03": "vehicles", "05": "services", "07": "services",
                   "08": "services", "04": "other", "09": "other", "13": "other"}   # 10-12: taxes, investment, loans: not operating
LINE_GROUPS = {"Computadores e tablets": "computers", "Perifericos, monitores e impressoras": "peripherals",
               "Componentes, pecas e armazenamento": "components", "Consumiveis": "consumables",
               "Assistencia tecnica e servicos": "services", "gGest - licencas e modulos": "software",
               "gGest - contratos anuais de actualizacao": "software", "gGest - subscricoes anuais/cloud": "software",
               "Servico fecho/abertura de ano": "software"}


def build(save, this_year, cut):
    run = saved.run_saved_query
    ly = this_year - 1
    md = f"{cut:%m-%d}"

    save("ytd_by_line", rows(run("sales_period_comparison_by_line", {"a_start": f"{ly}-01-01", "a_end": f"{ly}-{md}",
                                                                     "b_start": f"{this_year}-01-01", "b_end": f"{this_year}-{md}"})[:10]))

    oh = {}
    for r in run("finance_operating_expenses_by_category", {"start_year": 2021}, limit=1000):
        g = OVERHEAD_GROUPS.get(r["category"][:2])
        if not g:
            continue
        row = oh.setdefault(r["year"], {"year": r["year"], "staff": 0, "rent": 0, "franchise": 0, "vehicles": 0, "services": 0, "other": 0})
        row[g] = round(row[g] + (r["net"] or 0), 2)
    save("overheads_yearly", [oh[y] for y in sorted(oh)])

    # series groups from the config (Inforbyte: Chip7 corner vs the shop), pivoted to the dashboard's columns
    sg = {}
    for r in run("sales_series_groups_by_year", {"start_year": 2022}):
        row = sg.setdefault(r["year"], {"year": r["year"]})
        k = "shop" if r["series_group"] == "Loja" else "chip7"
        row[f"{k}_net"], row[f"{k}_margin_pct"] = r["net"], r["margin_pct"]
        if k == "chip7":
            row.update(chip7_margin=r["margin"], chip7_documents=r["documents"], chip7_share_pct=r["share_pct"])
    save("chip7_vs_shop", [sg[y] for y in sorted(sg)])

    mix = {}
    for r in run("sales_business_lines_by_year", limit=1000):
        row = mix.setdefault(r["year"], {"year": r["year"], "computers": 0, "peripherals": 0, "components": 0, "consumables": 0,
                                         "services": 0, "software": 0, "other": 0})
        k = LINE_GROUPS.get(r["business_line"], "other")
        row[k] = round(row[k] + (r["net_sales"] or 0), 2)
    save("lines_by_year", [mix[y] for y in sorted(mix)])

    save("labour_yearly", rows(run("repairs_revenue_by_year"), ["year", "repairs", "labour_net", "labour_invoices", "labour_per_invoice",
                                                                "orders_with_value_pct"]))

    save("replacement_leads", rows(run("repairs_replacement_leads", {"limit": 25}),
                                   ["repair_id", "opened_on", "customer_name", "equipment", "brand", "lead_reason", "device_repairs",
                                    "net_bought_last_3y"]))
    save("dead_stock", rows(run("finance_dead_stock_items", {"as_of": cut.isoformat(), "limit": 25}),
                            ["item_code", "description", "group_name", "qty", "stock_value", "last_sale", "days_without_movement"]))
    save("low_margin_items", rows(run("sales_low_margin_items", {"start": f"{this_year - 3}-01-01", "limit": 20}),
                                  ["item_code", "description", "brand_name", "qty", "net_sales", "gross_margin", "margin_pct"]))
    save("open_repairs", rows(run("repairs_open_backlog", {"as_of": cut.isoformat()})[:30],
                              ["repair_id", "opened_on", "age_days", "status", "equipment_type", "customer_name", "order_net"]))

    save("days_to_pay", rows(run("finance_days_to_pay_by_year"), ["year", "invoices", "weighted_avg_days", "avg_days",
                                                                  "pct_within_30d", "pct_over_60d"]))

    # one column per top-2 user (key = first name, lowercased), everyone else in "others"
    urs = run("management_sales_by_user", {"start_year": 2022, "end_year": this_year})
    tot = {}
    for r in urs:
        tot[r["user_name"]] = tot.get(r["user_name"], 0) + (r["net_sales"] or 0)
    top = {u: (u.split() or ["user"])[0].lower() for u in sorted(tot, key=tot.get, reverse=True)[:2]}
    users = {}
    for r in urs:
        row = users.setdefault(r["year"], {"year": r["year"], **{k: 0 for k in top.values()}, "others": 0})
        k = top.get(r["user_name"], "others")
        row[k] = round(row[k] + (r["net_sales"] or 0), 2)
    save("sales_by_user", [users[y] for y in sorted(users)])

    dq = []
    for r in run("sales_data_quality_by_year"):
        dq.append({"year": r["year"], "zz_share_pct": r["zz_share_pct"],
                   "estimated_cost_pct": round(100 * (r["net_with_estimated_cost"] or 0) / r["net_sales"], 2) if r["net_sales"] else None,
                   "zz_generic_net": r["zz_generic_net"], "zz_lines": r["zz_lines"]})
    save("data_quality", dq)

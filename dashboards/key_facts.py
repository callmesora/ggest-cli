"""Key facts quoted in the dashboard's summary tab (Resumo).

Each fact is one row: id, value, unit (eur | pct | count | year), description, source (saved query / view).
Imported by export_datasets.py; run it on its own to print the facts:  py dashboards/key_facts.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import db, saved  # noqa: E402

SERVICE_LINES = {"Assistencia tecnica e servicos", "gGest - licencas e modulos", "Servico fecho/abertura de ano",
                 "gGest - contratos anuais de actualizacao", "gGest - subscricoes anuais/cloud"}


def key_facts(this_year, cut):
    run = saved.run_saved_query
    ly, cy = this_year - 1, this_year
    facts = []

    def add(fid, value, unit, desc, source):
        facts.append({"id": fid, "value": round(value, 2) if isinstance(value, float) else value,
                      "unit": unit, "description": desc, "source": source})

    # Margin before / after
    for fid, a, b in (("margin_2017_22", 2017, 2022), ("margin_2023_now", 2023, cy)):
        r = db.rows("SELECT 100.0*SUM(margin)/SUM(net) AS m FROM sales_facts WHERE year BETWEEN ? AND ?", (a, b))[0]
        add(fid, r["m"], "pct", f"Margem bruta % {a}–{b}", "sales_facts")

    # Services + software share of sales and margin (last 3 complete years)
    lines = run("sales_business_lines", {"start": f"{cy - 3}-01-01", "end": f"{ly}-12-31"})
    tot_n = sum(r["net_sales"] for r in lines); tot_m = sum(r["gross_margin"] for r in lines)
    sv = [r for r in lines if r["business_line"] in SERVICE_LINES]
    add("svc_sales_share", 100 * sum(r["net_sales"] for r in sv) / tot_n, "pct",
        f"Peso de assistência, software gGest e fecho de ano nas vendas {cy - 3}–{ly}", "sales_business_lines")
    add("svc_margin_share", 100 * sum(r["gross_margin"] for r in sv) / tot_m, "pct",
        f"Peso de assistência, software gGest e fecho de ano na margem {cy - 3}–{ly}", "sales_business_lines")

    # Big deals last year
    big = run("sales_big_deals", {"start": f"{ly}-01-01", "end": f"{ly}-12-31", "min_net": 5000})
    add("big_deals_count_ly", len(big), "count", f"Negócios ≥ 5 000 € em {ly}", "sales_big_deals")
    add("big_deals_net_ly", sum(r["net"] for r in big), "eur", f"Vendas dos negócios ≥ 5 000 € em {ly}", "sales_big_deals")
    add("big_deals_margin_pct_ly", 100 * sum(r["gross_margin"] for r in big) / max(1, sum(r["net"] for r in big)), "pct",
        f"Margem % dos negócios ≥ 5 000 € em {ly}", "sales_big_deals")

    # Year to date: gap and the part explained by big deals
    md = f"{cut:%m-%d}"
    q = """SELECT SUM(net) AS net, SUM(CASE WHEN net >= 5000 THEN net ELSE 0 END) AS big
           FROM sales_docs WHERE is_cancelled = 0 AND is_internal = 0 AND doc_class IN ('invoice','credit_note')
           AND year = ? AND substr(doc_date, 6, 5) <= ?"""
    cur, prev = db.rows(q, (cy, md))[0], db.rows(q, (ly, md))[0]
    add("ytd_gap", prev["net"] - cur["net"], "eur", "Diferença de vendas face ao mesmo período do ano anterior", "sales_docs")
    add("ytd_gap_big_deals", prev["big"] - cur["big"], "eur", "Parte da diferença que vem de negócios ≥ 5 000 €", "sales_docs")
    add("ytd_gap_big_share", 100 * (prev["big"] - cur["big"]) / (prev["net"] - cur["net"]) if prev["net"] != cur["net"] else None,
        "pct", "Peso dos negócios ≥ 5 000 € na diferença face ao ano anterior", "sales_docs")

    # Recurring revenue: contract customers
    rec = {r["year"]: r for r in run("sales_recurring_revenue_by_year") if r["stream"] == "gGest contrato anual actualizacao"}
    for fid, y in (("contract_customers_2020", 2020), ("contract_customers_ly", ly), ("contract_customers_cy", cy)):
        add(fid, (rec.get(y) or {}).get("customers", 0), "count", f"Clientes com contrato anual de atualização gGest em {y}",
            "sales_recurring_revenue_by_year")

    # New customers
    nc = {r["year"]: r for r in run("customers_new_vs_returning")}
    add("new_customers_2018", nc[2018]["new_customers"], "count", "Clientes novos em 2018", "customers_new_vs_returning")
    add("new_customers_ly", nc[ly]["new_customers"], "count", f"Clientes novos em {ly}", "customers_new_vs_returning")

    # Segments (all time)
    seg = {}
    for r in run("customers_segment_by_year"):
        s = seg.setdefault(r["segment"], [0.0, 0.0]); s[0] += r["net_sales"] or 0; s[1] += r["gross_margin"] or 0
    for fid, k in (("margin_companies", "empresa"), ("margin_private", "particular"), ("margin_public", "publico")):
        add(fid, 100 * seg[k][1] / seg[k][0], "pct", f"Margem % do segmento {k} desde 2017", "customers_segment_by_year")

    # RFM
    rfm = {r["rfm_label"][:1]: r for r in run("customers_rfm_summary")}
    add("champions_count", rfm["1"]["customers"], "count", "Clientes campeões (últimos 3 anos)", "customers_rfm_summary")
    add("champions_share", rfm["1"]["share_pct"], "pct", "Peso dos clientes campeões nas vendas dos últimos 3 anos", "customers_rfm_summary")
    add("cant_lose_count", rfm["4"]["customers"], "count", "Clientes 'não pode perder' parados", "customers_rfm_summary")
    add("cant_lose_net", rfm["4"]["net_sales"], "eur", "Compras dos clientes 'não pode perder' (últimos 3 anos)", "customers_rfm_summary")

    # Geography
    geo = {r["island"]: r for r in run("customers_geography", {"level": "island"})}
    add("faial_share", geo["Faial"]["share_pct"], "pct", "Peso do Faial nas vendas desde 2017", "customers_geography")
    add("pico_share", geo["Pico"]["share_pct"], "pct", "Peso do Pico nas vendas desde 2017", "customers_geography")

    # Repairs
    rv = [r for r in run("repairs_revenue_by_year") if 2021 <= r["year"] <= ly]
    add("repairs_no_value_pct", 100 - 100 * sum(r["orders_with_value"] for r in rv) / sum(r["repairs"] for r in rv), "pct",
        f"Ordens de assistência sem valor, 2021–{ly}", "repairs_revenue_by_year")
    rs = [r for r in run("repairs_replacement_sales") if str(r["period"]).isdigit() and 2021 <= int(r["period"]) <= ly]
    add("repairs_conversion_pct", 100 * sum(r["followed_by_equipment_sale"] for r in rs) / sum(r["repairs"] for r in rs), "pct",
        f"Reparações seguidas de compra de equipamento na loja em 60 dias, 2021–{ly}", "repairs_replacement_sales")
    add("uneconomical_bought_pct", 100 * sum(r["uneconomical_bought_here"] for r in rs) / max(1, sum(r["uneconomical_repairs"] for r in rs)),
        "pct", f"Quando não compensa reparar, % que compra na loja, 2021–{ly}", "repairs_replacement_sales")
    vol = db.rows("SELECT year, COUNT(*) AS n FROM repairs GROUP BY 1 ORDER BY n DESC LIMIT 1")[0]
    add("repairs_peak_year", vol["year"], "year", "Ano com mais assistências", "repairs")
    add("repairs_peak", vol["n"], "count", "Assistências no ano de pico", "repairs")
    add("repairs_ly", db.rows("SELECT COUNT(*) AS n FROM repairs WHERE year = ?", (ly,))[0]["n"], "count", f"Assistências em {ly}", "repairs")
    ob = run("repairs_open_backlog", {"as_of": cut.isoformat()})
    add("open_repairs", len(ob), "count", "Ordens de assistência por fechar", "repairs_open_backlog")
    add("open_repairs_1y", sum(1 for r in ob if r["age_band"] == ">1 ano"), "count", "Ordens por fechar há mais de um ano", "repairs_open_backlog")

    # Finance
    fr = {r["year"]: r for r in run("finance_freight_costs_by_year")}
    add("freight_absorbed_ly", fr[ly]["freight_absorbed"], "eur", f"Portes pagos e não cobrados aos clientes em {ly}", "finance_freight_costs_by_year")
    aging = run("finance_receivables_aging")
    add("receivables_over_90", sum(r["open_amount"] for r in aging if r["bucket"][:1] in "34"), "eur",
        "Dívidas de clientes vencidas há mais de 90 dias (com IVA)", "finance_receivables_aging")
    return facts


if __name__ == "__main__":
    from datetime import date
    last = db.rows("SELECT MAX(doc_date) AS d FROM sales_docs WHERE is_cancelled = 0")[0]["d"]
    for f in key_facts(int(last[:4]), date.fromisoformat(last)):
        print(f"{f['id']:28} {f['value']!s:>12} {f['unit']:6} {f['description']}")

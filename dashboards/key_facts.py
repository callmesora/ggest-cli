"""Key facts quoted in the dashboard's summary tab (Resumo).

Each fact is one row: id, value, unit (eur | pct | count | year), description, source (saved query / view).
Used by export_datasets.py; run it on its own to print the facts:  uv run python dashboards/key_facts.py
"""

from __future__ import annotations

import sys
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import db
from dashboards.common import Context, Row, by_key, col_sum, is_year
from dashboards.common import run_saved as run

SERVICE_LINES = {
    "Assistencia tecnica e servicos",
    "gGest - licencas e modulos",
    "Servico fecho/abertura de ano",
    "gGest - contratos anuais de actualizacao",
    "gGest - subscricoes anuais/cloud",
}
BIG_DEAL = 5000
CONTRACT_STREAM = "gGest contrato anual actualizacao"
FIRST_REPAIR_YEAR = 2021  # repair values are reliable from this year on
YTD_SQL = """SELECT SUM(net) AS net, SUM(CASE WHEN net >= 5000 THEN net ELSE 0 END) AS big
           FROM sales_docs WHERE is_cancelled = 0 AND is_internal = 0 AND doc_class IN ('invoice','credit_note')
           AND year = ? AND substr(doc_date, 6, 5) <= ?"""


def fact(fid: str, value: Any, unit: str, desc: str, source: str) -> Row:
    """One key-fact row (floats rounded to 2 decimals)."""
    return {
        "id": fid,
        "value": round(value, 2) if isinstance(value, float) else value,
        "unit": unit,
        "description": desc,
        "source": source,
    }


def margin_facts(ctx: Context) -> list[Row]:
    """Gross margin % before and after 2023."""
    sql = "SELECT 100.0*SUM(margin)/SUM(net) AS m FROM sales_facts WHERE year BETWEEN ? AND ?"
    out = []
    for fid, a, b in (("margin_2017_22", 2017, 2022), ("margin_2023_now", 2023, ctx.this_year)):
        out.append(fact(fid, db.rows(sql, (a, b))[0]["m"], "pct", f"Margem bruta % {a}\N{EN DASH}{b}", "sales_facts"))
    return out


def service_share_facts(ctx: Context) -> list[Row]:
    """Services + software share of sales and margin (last 3 complete years)."""
    cy, ly = ctx.this_year, ctx.ly
    lines = run("sales_business_lines", {"start": f"{cy - 3}-01-01", "end": f"{ly}-12-31"})
    tot_n = sum(r["net_sales"] for r in lines)
    tot_m = sum(r["gross_margin"] for r in lines)
    sv = [r for r in lines if r["business_line"] in SERVICE_LINES]
    what = "Peso de assistência, software gGest e fecho de ano"
    return [
        fact(
            "svc_sales_share",
            100 * sum(r["net_sales"] for r in sv) / tot_n,
            "pct",
            f"{what} nas vendas {cy - 3}\N{EN DASH}{ly}",
            "sales_business_lines",
        ),
        fact(
            "svc_margin_share",
            100 * sum(r["gross_margin"] for r in sv) / tot_m,
            "pct",
            f"{what} na margem {cy - 3}\N{EN DASH}{ly}",
            "sales_business_lines",
        ),
    ]


def big_deal_facts(ctx: Context) -> list[Row]:
    """Count, sales and margin of the deals of 5 000 EUR or more last year."""
    ly = ctx.ly
    big = run("sales_big_deals", {"start": f"{ly}-01-01", "end": f"{ly}-12-31", "min_net": BIG_DEAL})
    net = sum(r["net"] for r in big)
    margin_pct = 100 * sum(r["gross_margin"] for r in big) / max(1, net)
    src = "sales_big_deals"
    return [
        fact("big_deals_count_ly", len(big), "count", f"Negócios ≥ 5 000 € em {ly}", src),
        fact("big_deals_net_ly", net, "eur", f"Vendas dos negócios ≥ 5 000 € em {ly}", src),
        fact("big_deals_margin_pct_ly", margin_pct, "pct", f"Margem % dos negócios ≥ 5 000 € em {ly}", src),
    ]


def ytd_gap_facts(ctx: Context) -> list[Row]:
    """Year-to-date sales gap vs last year and the part explained by big deals."""
    cur = db.rows(YTD_SQL, (ctx.this_year, ctx.md))[0]
    prev = db.rows(YTD_SQL, (ctx.ly, ctx.md))[0]
    gap, big_gap = prev["net"] - cur["net"], prev["big"] - cur["big"]
    big_share = 100 * big_gap / gap if prev["net"] != cur["net"] else None
    return [
        fact("ytd_gap", gap, "eur", "Diferença de vendas face ao mesmo período do ano anterior", "sales_docs"),
        fact("ytd_gap_big_deals", big_gap, "eur", "Parte da diferença que vem de negócios ≥ 5 000 €", "sales_docs"),
        fact(
            "ytd_gap_big_share",
            big_share,
            "pct",
            "Peso dos negócios ≥ 5 000 € na diferença face ao ano anterior",
            "sales_docs",
        ),
    ]


def contract_customer_facts(ctx: Context) -> list[Row]:
    """Customers with an annual gGest update contract in 2020, last year and this year."""
    rec = by_key((r for r in run("sales_recurring_revenue_by_year") if r["stream"] == CONTRACT_STREAM), "year")
    years = (
        ("contract_customers_2020", 2020),
        ("contract_customers_ly", ctx.ly),
        ("contract_customers_cy", ctx.this_year),
    )
    return [
        fact(
            fid,
            (rec.get(y) or {}).get("customers", 0),
            "count",
            f"Clientes com contrato anual de atualização gGest em {y}",
            "sales_recurring_revenue_by_year",
        )
        for fid, y in years
    ]


def new_customer_facts(ctx: Context) -> list[Row]:
    """New customers in 2018 and last year."""
    nc = by_key(run("customers_new_vs_returning"), "year")
    src = "customers_new_vs_returning"
    return [
        fact("new_customers_2018", nc[2018]["new_customers"], "count", "Clientes novos em 2018", src),
        fact("new_customers_ly", nc[ctx.ly]["new_customers"], "count", f"Clientes novos em {ctx.ly}", src),
    ]


def segment_facts(_ctx: Context) -> list[Row]:
    """Gross margin % per customer segment (all time)."""
    seg: dict[str, list[float]] = {}
    for r in run("customers_segment_by_year"):
        s = seg.setdefault(r["segment"], [0.0, 0.0])
        s[0] += r["net_sales"] or 0
        s[1] += r["gross_margin"] or 0
    return [
        fact(
            fid, 100 * seg[k][1] / seg[k][0], "pct", f"Margem % do segmento {k} desde 2017", "customers_segment_by_year"
        )
        for fid, k in (("margin_companies", "empresa"), ("margin_private", "particular"), ("margin_public", "publico"))
    ]


def rfm_facts(_ctx: Context) -> list[Row]:
    """Champions and can't-lose customers (RFM, last 3 years)."""
    rfm = {r["rfm_label"][:1]: r for r in run("customers_rfm_summary")}
    src = "customers_rfm_summary"
    return [
        fact("champions_count", rfm["1"]["customers"], "count", "Clientes campeões (últimos 3 anos)", src),
        fact(
            "champions_share",
            rfm["1"]["share_pct"],
            "pct",
            "Peso dos clientes campeões nas vendas dos últimos 3 anos",
            src,
        ),
        fact("cant_lose_count", rfm["4"]["customers"], "count", "Clientes 'não pode perder' parados", src),
        fact(
            "cant_lose_net",
            rfm["4"]["net_sales"],
            "eur",
            "Compras dos clientes 'não pode perder' (últimos 3 anos)",
            src,
        ),
    ]


def geography_facts(_ctx: Context) -> list[Row]:
    """Share of sales of the two main islands."""
    geo = by_key(run("customers_geography", {"level": "region"}), "region")
    src = "customers_geography"
    return [
        fact("faial_share", geo["Faial"]["share_pct"], "pct", "Peso do Faial nas vendas desde 2017", src),
        fact("pico_share", geo["Pico"]["share_pct"], "pct", "Peso do Pico nas vendas desde 2017", src),
    ]


def in_repair_window(period: Any, last_year: int) -> bool:
    """True for a plain-year period between FIRST_REPAIR_YEAR and ``last_year`` (inclusive)."""
    return is_year(period) and FIRST_REPAIR_YEAR <= int(period) <= last_year


def repair_ratio_facts(ctx: Context) -> list[Row]:
    """Repairs without value and repairs followed by an equipment sale (2021 to last year)."""
    ly = ctx.ly
    rv = [r for r in run("repairs_revenue_by_year") if in_repair_window(r["year"], ly)]
    rs = [r for r in run("repairs_replacement_sales") if in_repair_window(r["period"], ly)]
    no_value = 100 - 100 * col_sum(rv, "orders_with_value") / col_sum(rv, "repairs")
    conversion = 100 * col_sum(rs, "followed_by_equipment_sale") / col_sum(rs, "repairs")
    bought = 100 * col_sum(rs, "uneconomical_bought_here") / max(1, col_sum(rs, "uneconomical_repairs"))
    return [
        fact(
            "repairs_no_value_pct",
            no_value,
            "pct",
            f"Ordens de assistência sem valor, 2021\N{EN DASH}{ly}",
            "repairs_revenue_by_year",
        ),
        fact(
            "repairs_conversion_pct",
            conversion,
            "pct",
            f"Reparações seguidas de compra de equipamento na loja em 60 dias, 2021\N{EN DASH}{ly}",
            "repairs_replacement_sales",
        ),
        fact(
            "uneconomical_bought_pct",
            bought,
            "pct",
            f"Quando não compensa reparar, % que compra na loja, 2021\N{EN DASH}{ly}",
            "repairs_replacement_sales",
        ),
    ]


def repair_volume_facts(ctx: Context) -> list[Row]:
    """Peak repair year, repairs last year and the open backlog."""
    ly = ctx.ly
    peak = db.rows("SELECT year, COUNT(*) AS n FROM repairs GROUP BY 1 ORDER BY n DESC LIMIT 1")[0]
    repairs_ly = db.rows("SELECT COUNT(*) AS n FROM repairs WHERE year = ?", (ly,))[0]["n"]
    ob = run("repairs_open_backlog", {"as_of": ctx.cut.isoformat()})
    over_1y = sum(1 for r in ob if r["age_band"] == ">1 ano")
    return [
        fact("repairs_peak_year", peak["year"], "year", "Ano com mais assistências", "repairs"),
        fact("repairs_peak", peak["n"], "count", "Assistências no ano de pico", "repairs"),
        fact("repairs_ly", repairs_ly, "count", f"Assistências em {ly}", "repairs"),
        fact("open_repairs", len(ob), "count", "Ordens de assistência por fechar", "repairs_open_backlog"),
        fact("open_repairs_1y", over_1y, "count", "Ordens por fechar há mais de um ano", "repairs_open_backlog"),
    ]


def finance_facts(ctx: Context) -> list[Row]:
    """Freight absorbed last year and receivables overdue by more than 90 days."""
    fr = by_key(run("finance_freight_costs_by_year"), "year")
    overdue = sum(r["open_amount"] for r in run("finance_receivables_aging") if r["bucket"][:1] in "34")
    return [
        fact(
            "freight_absorbed_ly",
            fr[ctx.ly]["freight_absorbed"],
            "eur",
            f"Portes pagos e não cobrados aos clientes em {ctx.ly}",
            "finance_freight_costs_by_year",
        ),
        fact(
            "receivables_over_90",
            overdue,
            "eur",
            "Dívidas de clientes vencidas há mais de 90 dias (com IVA)",
            "finance_receivables_aging",
        ),
    ]


SECTIONS: list[Callable[[Context], list[Row]]] = [
    margin_facts,
    service_share_facts,
    big_deal_facts,
    ytd_gap_facts,
    contract_customer_facts,
    new_customer_facts,
    segment_facts,
    rfm_facts,
    geography_facts,
    repair_ratio_facts,
    repair_volume_facts,
    finance_facts,
]


def key_facts(this_year: int, cut: date) -> list[Row]:
    """All key facts, in the order the summary tab lists them."""
    ctx = Context(last=cut.isoformat(), cut=cut, this_year=this_year)
    return [f for section in SECTIONS for f in section(ctx)]


def main() -> None:
    """Print the key facts for the current snapshot."""
    ctx = Context.load()
    for f in key_facts(ctx.this_year, ctx.cut):
        print(f"{f['id']:28} {f['value']!s:>12} {f['unit']:6} {f['description']}")


if __name__ == "__main__":
    main()

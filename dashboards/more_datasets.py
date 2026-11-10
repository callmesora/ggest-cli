"""Extra dashboard datasets: seasonality, invoice sizes, big deals, returns, RFM, geography, cohorts, repair mix,
repair work, faults, payment methods, freight, slow payers. Listed in :data:`DATASETS`, exported by export_datasets.py.
"""

from __future__ import annotations

from dashboards.common import Context, Dataset, Row, is_year, pick, pivot_sum, sorted_values
from dashboards.common import run_saved as run

FAULTS = {
    "nao_arranca_bloqueia": "Não arranca / bloqueia",
    "ecra_imagem": "Ecrã / imagem",
    "nao_liga": "Não liga",
    "impressora": "Impressora",
    "outro": "Outro",
    "bateria_carregador_energia": "Bateria / carregador",
    "software_windows_instalacao": "Windows / software",
    "dano_fisico_liquido": "Dano físico / líquido",
    "teclado_rato": "Teclado / rato",
    "lento_virus": "Lento / vírus",
    "internet_email": "Internet / email",
    "recuperacao_dados": "Recuperação de dados",
    "manutencao_upgrade": "Manutenção / upgrade",
    "sobreaquecimento_desliga": "Sobreaquecimento",
    "som_portas_perifericos": "Som / portas",
}
MONTHS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
EQUIPMENT_GROUPS = {"notebook": "notebook", "desktop": "desktop", "impressora": "printer", "tablet_telemovel": "mobile"}
COHORT_YEARS = (1, 2, 3, 5)
BIG_DEAL_COLUMNS = ("doc_id", "doc_date", "customer_name", "main_business_line", "net", "margin_pct")
RETURNS_COLUMNS = (
    "year",
    "invoiced_net",
    "credited_net",
    "credited_pct_of_invoiced",
    "cancelled_docs",
    "cancelled_pct_of_docs",
)
FREIGHT_COLUMNS = ("year", "freight_paid_on_purchases", "freight_charged_on_sales", "freight_absorbed", "recovery_pct")
SLOW_PAYER_COLUMNS = (
    "customer_code",
    "customer_name",
    "invoices",
    "invoiced_gross",
    "weighted_days_to_pay",
    "open_now",
)


def seasonality(ctx: Context) -> list[Row]:
    """Average sales per calendar month (complete years up to last year)."""
    return [
        {
            "month": MONTHS[r["month_no"] - 1],
            "month_no": r["month_no"],
            "avg_net_sales": r["avg_net_sales"],
            "margin_pct": r["margin_pct"],
            "share_of_year_pct": r["share_of_year_pct"],
        }
        for r in run("sales_seasonality_by_month", {"end_year": ctx.ly})
    ]


def ticket_bands_yearly(_ctx: Context) -> list[Row]:
    """Net sales per invoice-size band (b1..b5, from the band label's first digit) and year."""
    bands: dict[int, Row] = {}
    for r in run("sales_ticket_bands_by_year", limit=1000):
        row = bands.setdefault(r["year"], {"year": r["year"], "b1": 0, "b2": 0, "b3": 0, "b4": 0, "b5": 0})
        row["b" + r["ticket_band"][0]] = r["net_sales"]
    return sorted_values(bands)


def cohorts(ctx: Context) -> list[Row]:
    """Customer retention 1, 2, 3 and 5 years after the first purchase, per cohort (current year left out)."""
    table: dict[int, Row] = {}
    for r in run("customers_cohort_retention", limit=1000):
        row = table.setdefault(
            r["cohort"],
            {"cohort": r["cohort"], "cohort_size": r["cohort_size"], "y1": None, "y2": None, "y3": None, "y5": None},
        )
        if r["years_after"] in COHORT_YEARS:
            row[f"y{r['years_after']}"] = r["retention_pct"]
    return [table[c] for c in sorted(table) if c < ctx.this_year]


def repairs_mix_yearly(_ctx: Context) -> list[Row]:
    """Repairs per equipment group and year."""
    return pivot_sum(
        run("repairs_equipment_mix", limit=1000),
        "period",
        ("notebook", "desktop", "printer", "mobile", "other"),
        lambda r: EQUIPMENT_GROUPS.get(r["key"], "other"),
        value="repairs",
        head=lambda r: {"year": int(r["period"])},
    )


def repairs_work_yearly(_ctx: Context) -> list[Row]:
    """Repairs per year with virus cleaning, OS reinstall and disk replacement counts."""
    return [
        {
            "year": int(r["period"]),
            "repairs": r["repairs"],
            "virus": r["limpeza_virus"],
            "reinstall": r["reinstalacao_so"],
            "disk": r["troca_disco"],
        }
        for r in run("repairs_work_done")
        if is_year(r["period"])
    ]


def repair_faults_5y(ctx: Context) -> list[Row]:
    """Top 12 fault categories over the last 5 complete years."""
    rows = run("repairs_fault_categories", {"start": f"{ctx.ly - 4}-01-01", "end": f"{ctx.ly}-12-31"})
    return [
        {
            "category": FAULTS.get(r["fault_category"], r["fault_category"]),
            "key": r["fault_category"],
            "repairs": r["repairs"],
            "share_pct": r["pct_of_period"],
        }
        for r in rows
    ][:12]


def payment_methods(_ctx: Context) -> list[Row]:
    """Receipts per payment method and year (MB Way and cheques grouped as 'other')."""
    return [
        {
            "year": int(r["period"]),
            "cash": r["cash"],
            "card": r["card"],
            "transfer": r["transfer"],
            "mb_reference": r["mb_reference"],
            "other": (r["mbway"] or 0) + (r["cheque_other"] or 0),
            "cash_pct": r["cash_pct"],
        }
        for r in run("finance_payment_methods")
        if is_year(r["period"])
    ]


def island_row(row: Row) -> Row:
    """The dashboard calls regions islands (column names kept for the published page)."""
    names = {"region": "island", "area": "locality"}
    return {names.get(k, k): v for k, v in row.items()}


DATASETS: list[Dataset] = [
    Dataset("seasonality", "Average sales per month", seasonality),
    Dataset("ticket_bands_yearly", "Sales by invoice size", ticket_bands_yearly),
    Dataset(
        "big_deals",
        "Largest deals (>= 5 000 EUR)",
        lambda _c: pick(run("sales_big_deals", {"min_net": 5000, "limit": 40}), BIG_DEAL_COLUMNS),
    ),
    Dataset(
        "returns_yearly",
        "Credit notes and cancellations per year",
        lambda _c: pick(run("sales_returns_cancellations_by_year"), RETURNS_COLUMNS),
    ),
    Dataset(
        "credit_reasons",
        "Top credit-note reasons",
        lambda _c: [r for r in run("sales_credit_cancel_reasons") if r["kind"] != "cancelled"][:10],
    ),
    Dataset(
        "rfm_summary",
        "RFM segments",
        lambda _c: [{**r, "segment": r["rfm_label"][2:]} for r in run("customers_rfm_summary")],
    ),
    Dataset(
        "geography_islands",
        "Sales per island",
        lambda _c: [island_row(r) for r in run("customers_geography", {"level": "region"}) if r["net_sales"]][:10],
    ),
    Dataset("cohorts", "Customer retention by cohort", cohorts),
    Dataset("repairs_mix_yearly", "Repairs per equipment group", repairs_mix_yearly),
    Dataset("repairs_work_yearly", "Repair work done per year", repairs_work_yearly),
    Dataset("repair_faults_5y", "Fault categories, last 5 years", repair_faults_5y),
    Dataset("payment_methods", "Payment methods per year", payment_methods),
    Dataset(
        "freight_yearly",
        "Freight paid, charged and absorbed",
        lambda _c: pick(run("finance_freight_costs_by_year"), FREIGHT_COLUMNS),
    ),
    Dataset(
        "slow_payers",
        "Slowest-paying customers",
        lambda _c: pick(run("finance_slow_payers", {"limit": 12}), SLOW_PAYER_COLUMNS),
    ),
]

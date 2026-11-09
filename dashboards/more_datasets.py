"""Extra dashboard datasets (seasonality, invoice sizes, big deals, returns, RFM, geography, cohorts, repair mix,
repair work, faults, payment methods, freight, slow payers). Called by export_datasets.py."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bi import saved  # noqa: E402

FAULTS = {"nao_arranca_bloqueia": "Não arranca / bloqueia", "ecra_imagem": "Ecrã / imagem", "nao_liga": "Não liga",
          "impressora": "Impressora", "outro": "Outro", "bateria_carregador_energia": "Bateria / carregador",
          "software_windows_instalacao": "Windows / software", "dano_fisico_liquido": "Dano físico / líquido",
          "teclado_rato": "Teclado / rato", "lento_virus": "Lento / vírus", "internet_email": "Internet / email",
          "recuperacao_dados": "Recuperação de dados", "manutencao_upgrade": "Manutenção / upgrade",
          "sobreaquecimento_desliga": "Sobreaquecimento", "som_portas_perifericos": "Som / portas"}
MONTHS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]


def build(save, this_year):
    run = saved.run_saved_query
    ly = this_year - 1

    save("seasonality", [{"month": MONTHS[r["month_no"] - 1], "month_no": r["month_no"], "avg_net_sales": r["avg_net_sales"],
                          "margin_pct": r["margin_pct"], "share_of_year_pct": r["share_of_year_pct"]}
                         for r in run("sales_seasonality_by_month", {"end_year": ly})])

    bands = {}
    for r in run("sales_ticket_bands_by_year", limit=1000):
        row = bands.setdefault(r["year"], {"year": r["year"], "b1": 0, "b2": 0, "b3": 0, "b4": 0, "b5": 0})
        row["b" + r["ticket_band"][0]] = r["net_sales"]
    save("ticket_bands_yearly", [bands[y] for y in sorted(bands)])

    save("big_deals", [{k: r[k] for k in ("doc_id", "doc_date", "customer_name", "main_business_line", "net", "margin_pct")}
                       for r in run("sales_big_deals", {"min_net": 5000, "limit": 40})])

    save("returns_yearly", [{k: r[k] for k in ("year", "invoiced_net", "credited_net", "credited_pct_of_invoiced",
                                               "cancelled_docs", "cancelled_pct_of_docs")}
                            for r in run("sales_returns_cancellations_by_year")])
    save("credit_reasons", [r for r in run("sales_credit_cancel_reasons") if r["kind"] != "cancelled"][:10])

    save("rfm_summary", [{**r, "segment": r["rfm_label"][2:]} for r in run("customers_rfm_summary")])
    save("geography_islands", [r for r in run("customers_geography", {"level": "island"}) if r["net_sales"]][:10])

    coh = {}
    for r in run("customers_cohort_retention", limit=1000):
        row = coh.setdefault(r["cohort"], {"cohort": r["cohort"], "cohort_size": r["cohort_size"], "y1": None, "y2": None, "y3": None, "y5": None})
        if r["years_after"] in (1, 2, 3, 5):
            row[f"y{r['years_after']}"] = r["retention_pct"]
    save("cohorts", [coh[c] for c in sorted(coh) if c < this_year])

    mix = {}
    groups = {"notebook": "notebook", "desktop": "desktop", "impressora": "printer", "tablet_telemovel": "mobile"}
    for r in run("repairs_equipment_mix", limit=1000):
        row = mix.setdefault(r["period"], {"year": int(r["period"]), "notebook": 0, "desktop": 0, "printer": 0, "mobile": 0, "other": 0})
        row[groups.get(r["key"], "other")] += r["repairs"]
    save("repairs_mix_yearly", [mix[p] for p in sorted(mix)])

    save("repairs_work_yearly", [{"year": int(r["period"]), "repairs": r["repairs"], "virus": r["limpeza_virus"],
                                  "reinstall": r["reinstalacao_so"], "disk": r["troca_disco"]}
                                 for r in run("repairs_work_done") if str(r["period"]).isdigit()])

    save("repair_faults_5y", [{"category": FAULTS.get(r["fault_category"], r["fault_category"]), "key": r["fault_category"],
                               "repairs": r["repairs"], "share_pct": r["pct_of_period"]}
                              for r in run("repairs_fault_categories", {"start": f"{ly - 4}-01-01", "end": f"{ly}-12-31"})][:12])

    save("payment_methods", [{"year": int(r["period"]), "cash": r["cash"], "card": r["card"], "transfer": r["transfer"],
                              "mb_reference": r["mb_reference"], "other": (r["mbway"] or 0) + (r["cheque_other"] or 0),
                              "cash_pct": r["cash_pct"]}
                             for r in run("finance_payment_methods") if str(r["period"]).isdigit()])

    save("freight_yearly", [{k: r[k] for k in ("year", "freight_paid_on_purchases", "freight_charged_on_sales",
                                               "freight_absorbed", "recovery_pct")} for r in run("finance_freight_costs_by_year")])

    save("slow_payers", [{k: r[k] for k in ("customer_code", "customer_name", "invoices", "invoiced_gross",
                                            "weighted_days_to_pay", "open_now")} for r in run("finance_slow_payers", {"limit": 12})])

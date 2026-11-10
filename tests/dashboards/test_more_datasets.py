"""Tests for the dataset builders in dashboards.more_datasets and dashboards.more_datasets2 (synthetic rows only)."""

from __future__ import annotations

from dashboards import more_datasets as m1
from dashboards import more_datasets2 as m2


def build(module, name):
    return {d.name: d.build for d in module.DATASETS}[name]


def test_seasonality(fake, ctx) -> None:
    fake.saved["sales_seasonality_by_month"] = [
        {"month_no": 12, "avg_net_sales": 1.0, "margin_pct": 2.0, "share_of_year_pct": 3.0, "extra": 0}
    ]
    assert m1.seasonality(ctx) == [
        {"month": "dez", "month_no": 12, "avg_net_sales": 1.0, "margin_pct": 2.0, "share_of_year_pct": 3.0}
    ]
    assert fake.calls[0][1] == {"end_year": 2025}


def test_ticket_bands(fake, ctx) -> None:
    fake.saved["sales_ticket_bands_by_year"] = [
        {"year": 2025, "ticket_band": "3: 100-500", "net_sales": 7.0},
        {"year": 2024, "ticket_band": "1: <20", "net_sales": 1.0},
    ]
    assert m1.ticket_bands_yearly(ctx) == [
        {"year": 2024, "b1": 1.0, "b2": 0, "b3": 0, "b4": 0, "b5": 0},
        {"year": 2025, "b1": 0, "b2": 0, "b3": 7.0, "b4": 0, "b5": 0},
    ]
    assert fake.calls[0][2] == {"limit": 1000}


def test_cohorts_skip_current_year_and_other_offsets(fake, ctx) -> None:
    fake.saved["customers_cohort_retention"] = [
        {"cohort": 2020, "cohort_size": 10, "years_after": 1, "retention_pct": 50.0},
        {"cohort": 2020, "cohort_size": 10, "years_after": 4, "retention_pct": 20.0},
        {"cohort": 2026, "cohort_size": 3, "years_after": 0, "retention_pct": 100.0},
    ]
    assert m1.cohorts(ctx) == [{"cohort": 2020, "cohort_size": 10, "y1": 50.0, "y2": None, "y3": None, "y5": None}]


def test_repairs_mix(fake, ctx) -> None:
    fake.saved["repairs_equipment_mix"] = [
        {"period": "2024", "key": "notebook", "repairs": 3},
        {"period": "2024", "key": "impressora", "repairs": 1},
        {"period": "2024", "key": "router", "repairs": 2},
    ]
    assert m1.repairs_mix_yearly(ctx) == [
        {"year": 2024, "notebook": 3, "desktop": 0, "printer": 1, "mobile": 0, "other": 2}
    ]


def test_repairs_work_faults_payments(fake, ctx) -> None:
    fake.saved["repairs_work_done"] = [
        {"period": "2024", "repairs": 5, "limpeza_virus": 1, "reinstalacao_so": 2, "troca_disco": 0},
        {"period": "Total", "repairs": 5, "limpeza_virus": 1, "reinstalacao_so": 2, "troca_disco": 0},
    ]
    fake.saved["repairs_fault_categories"] = [
        {"fault_category": "nao_liga", "repairs": 2, "pct_of_period": 40.0},
        {"fault_category": "novo", "repairs": 1, "pct_of_period": 20.0},
    ]
    fake.saved["finance_payment_methods"] = [
        {
            "period": "2025",
            "cash": 1,
            "card": 2,
            "transfer": 3,
            "mb_reference": 4,
            "mbway": None,
            "cheque_other": 5,
            "cash_pct": 6.0,
        },
        {
            "period": "Total",
            "cash": 0,
            "card": 0,
            "transfer": 0,
            "mb_reference": 0,
            "mbway": 0,
            "cheque_other": 0,
            "cash_pct": 0,
        },
    ]
    assert m1.repairs_work_yearly(ctx) == [{"year": 2024, "repairs": 5, "virus": 1, "reinstall": 2, "disk": 0}]
    faults = m1.repair_faults_5y(ctx)
    assert [f["category"] for f in faults] == ["Não liga", "novo"]
    assert fake.calls[-1][1] == {"start": "2021-01-01", "end": "2025-12-31"}
    assert m1.payment_methods(ctx) == [
        {"year": 2025, "cash": 1, "card": 2, "transfer": 3, "mb_reference": 4, "other": 5, "cash_pct": 6.0}
    ]


def test_simple_more_datasets(fake, ctx) -> None:
    fake.saved["customers_rfm_summary"] = [{"rfm_label": "1 Campeões", "customers": 3}]
    fake.saved["customers_geography"] = [
        {"region": "A", "area": None, "net_sales": 0},
        {"region": "B", "area": None, "net_sales": 2.0},
    ]
    fake.saved["sales_credit_cancel_reasons"] = [{"kind": "cancelled"}, {"kind": "credit"}]
    assert build(m1, "rfm_summary")(ctx) == [{"rfm_label": "1 Campeões", "customers": 3, "segment": "Campeões"}]
    assert build(m1, "geography_islands")(ctx) == [{"island": "B", "locality": None, "net_sales": 2.0}]
    assert build(m1, "credit_reasons")(ctx) == [{"kind": "credit"}]


def test_ytd_by_line_params_and_cleaning(fake, ctx) -> None:
    fake.saved["sales_period_comparison_by_line"] = [{"line": f"L{i}�"} for i in range(12)]
    out = m2.ytd_by_line(ctx)
    assert len(out) == 10
    assert out[0] == {"line": "L0"}
    assert fake.calls[0][1] == {
        "a_start": "2025-01-01",
        "a_end": "2025-03-07",
        "b_start": "2026-01-01",
        "b_end": "2026-03-07",
    }


def test_overheads_skip_non_operating(fake, ctx) -> None:
    fake.saved["finance_operating_expenses_by_category"] = [
        {"year": 2024, "category": "01 Pessoal", "net": 10.0},
        {"year": 2024, "category": "07 Servicos", "net": 1.0},
        {"year": 2024, "category": "08 Servicos", "net": None},
        {"year": 2023, "category": "10 Impostos", "net": 99.0},
    ]
    assert m2.overheads_yearly(ctx) == [
        {"year": 2024, "staff": 10.0, "rent": 0, "franchise": 0, "vehicles": 0, "services": 1.0, "other": 0}
    ]


def test_chip7_vs_shop(fake, ctx) -> None:
    fake.saved["sales_series_groups_by_year"] = [
        {
            "year": 2025,
            "series_group": "Loja",
            "net": 10.0,
            "margin_pct": 20.0,
            "margin": 2.0,
            "documents": 5,
            "share_pct": 80.0,
        },
        {
            "year": 2025,
            "series_group": "Canto",
            "net": 2.5,
            "margin_pct": 40.0,
            "margin": 1.0,
            "documents": 2,
            "share_pct": 20.0,
        },
    ]
    assert m2.chip7_vs_shop(ctx) == [
        {
            "year": 2025,
            "shop_net": 10.0,
            "shop_margin_pct": 20.0,
            "chip7_net": 2.5,
            "chip7_margin_pct": 40.0,
            "chip7_margin": 1.0,
            "chip7_documents": 2,
            "chip7_share_pct": 20.0,
        }
    ]


def test_lines_by_year(fake, ctx) -> None:
    fake.saved["sales_business_lines_by_year"] = [
        {"year": 2025, "business_line": "Consumiveis", "net_sales": 3.0},
        {"year": 2025, "business_line": "gGest - licencas e modulos", "net_sales": 1.0},
        {"year": 2025, "business_line": "Servico fecho/abertura de ano", "net_sales": 1.0},
        {"year": 2025, "business_line": "Novidade", "net_sales": 0.5},
    ]
    assert m2.lines_by_year(ctx) == [
        {
            "year": 2025,
            "computers": 0,
            "peripherals": 0,
            "components": 0,
            "consumables": 3.0,
            "services": 0,
            "software": 2.0,
            "other": 0.5,
        }
    ]


def test_top_user_columns() -> None:
    rows = [
        {"user_name": "Ana Silva", "net_sales": 5.0},
        {"user_name": "Bruno", "net_sales": 9.0},
        {"user_name": "", "net_sales": 7.0},
        {"user_name": "Ana Silva", "net_sales": None},
    ]
    assert m2.top_user_columns(rows) == {"Bruno": "bruno", "": "user"}
    assert m2.top_user_columns(rows, n=3) == {"Bruno": "bruno", "": "user", "Ana Silva": "ana"}


def test_sales_by_user(fake, ctx) -> None:
    fake.saved["management_sales_by_user"] = [
        {"year": 2024, "user_name": "Ana Silva", "net_sales": 5.0},
        {"year": 2024, "user_name": "Bruno Costa", "net_sales": 9.0},
        {"year": 2025, "user_name": "Diogo", "net_sales": 1.0},
        {"year": 2025, "user_name": "Ana Silva", "net_sales": 2.0},
    ]
    out = m2.sales_by_user(ctx)
    assert out == [
        {"year": 2024, "ana": 5.0, "bruno": 9.0, "others": 0},
        {"year": 2025, "ana": 2.0, "bruno": 0, "others": 1.0},
    ]
    assert list(out[0]) == ["year", "bruno", "ana", "others"]
    assert fake.calls[0][1] == {"start_year": 2022, "end_year": 2026}


def test_data_quality(fake, ctx) -> None:
    fake.saved["sales_data_quality_by_year"] = [
        {
            "year": 2024,
            "zz_share_pct": 1.0,
            "net_with_estimated_cost": 25.0,
            "net_sales": 200.0,
            "zz_generic_net": 2.0,
            "zz_lines": 3,
        },
        {
            "year": 2025,
            "zz_share_pct": 0.0,
            "net_with_estimated_cost": None,
            "net_sales": 0,
            "zz_generic_net": 0,
            "zz_lines": 0,
        },
    ]
    out = m2.data_quality(ctx)
    assert out[0]["estimated_cost_pct"] == 12.5
    assert out[1]["estimated_cost_pct"] is None


def test_action_lists_select_and_clean(fake, ctx) -> None:
    row = {c: f"v�{c}" for c in [*m2.OPEN_REPAIR_COLUMNS, "hidden"]}
    fake.saved["repairs_open_backlog"] = [row] * 35
    out = build(m2, "open_repairs")(ctx)
    assert len(out) == 30
    assert list(out[0]) == m2.OPEN_REPAIR_COLUMNS
    assert out[0]["status"] == "vstatus"
    assert fake.calls[-1][1] == {"as_of": "2026-03-07"}

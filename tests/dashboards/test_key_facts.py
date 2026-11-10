"""Tests for dashboards.key_facts with a synthetic backend (no real names or figures)."""

from __future__ import annotations

import pytest

from bi import db
from dashboards import key_facts as kf

SVC = "Assistencia tecnica e servicos"


@pytest.fixture
def facts_backend(fake):
    """Synthetic answers for every query key_facts uses (cut-off 2026-03-07, so last year = 2025)."""
    fake.sql += [
        ("100.0*SUM(margin)", [{"m": 25.123}]),
        ("substr(doc_date", [{"net": 100.0, "big": 40.0}]),  # same answer for both years -> zero gap
        ("ORDER BY n DESC", [{"year": 2019, "n": 900}]),
        ("FROM repairs WHERE year", [{"n": 400}]),
    ]
    fake.saved.update(
        {
            "sales_business_lines": [
                {"business_line": SVC, "net_sales": 30.0, "gross_margin": 15.0},
                {"business_line": "Consumiveis", "net_sales": 70.0, "gross_margin": 5.0},
            ],
            "sales_big_deals": [{"net": 6000.0, "gross_margin": 600.0}, {"net": 4000.0, "gross_margin": 400.0}],
            "sales_recurring_revenue_by_year": [
                {"year": 2025, "stream": kf.CONTRACT_STREAM, "customers": 12},
                {"year": 2025, "stream": "other", "customers": 99},
            ],
            "customers_new_vs_returning": [{"year": 2018, "new_customers": 50}, {"year": 2025, "new_customers": 30}],
            "customers_segment_by_year": [
                {"segment": "empresa", "net_sales": 100.0, "gross_margin": 20.0},
                {"segment": "particular", "net_sales": 50.0, "gross_margin": None},
                {"segment": "particular", "net_sales": 50.0, "gross_margin": 30.0},
                {"segment": "publico", "net_sales": 10.0, "gross_margin": 1.0},
            ],
            "customers_rfm_summary": [
                {"rfm_label": "1 Campeões", "customers": 5, "share_pct": 40.0, "net_sales": 1.0},
                {"rfm_label": "4 Não pode perder", "customers": 2, "share_pct": 5.0, "net_sales": 300.0},
            ],
            "customers_geography": [{"region": "Faial", "share_pct": 70.0}, {"region": "Pico", "share_pct": 20.0}],
            "repairs_revenue_by_year": [
                {"year": 2020, "orders_with_value": 0, "repairs": 100},
                {"year": 2021, "orders_with_value": 60, "repairs": 100},
                {"year": 2025, "orders_with_value": 90, "repairs": 100},
            ],
            "repairs_replacement_sales": [
                {
                    "period": "2022",
                    "followed_by_equipment_sale": 5,
                    "repairs": 50,
                    "uneconomical_bought_here": 1,
                    "uneconomical_repairs": 4,
                },
                {
                    "period": "Total",
                    "followed_by_equipment_sale": 99,
                    "repairs": 99,
                    "uneconomical_bought_here": 99,
                    "uneconomical_repairs": 99,
                },
            ],
            "repairs_open_backlog": [{"age_band": ">1 ano"}, {"age_band": "<30 dias"}],
            "finance_freight_costs_by_year": [{"year": 2025, "freight_absorbed": 123.456}],
            "finance_receivables_aging": [
                {"bucket": "1: 0-30", "open_amount": 1.0},
                {"bucket": "3: 91-180", "open_amount": 10.0},
                {"bucket": "4: >180", "open_amount": 5.0},
            ],
        }
    )
    return fake


def test_fact_rounds_floats_only() -> None:
    assert kf.fact("a", 1.23456, "pct", "d", "s") == {
        "id": "a",
        "value": 1.23,
        "unit": "pct",
        "description": "d",
        "source": "s",
    }
    assert kf.fact("b", 7, "count", "d", "s")["value"] == 7
    assert kf.fact("c", None, "pct", "d", "s")["value"] is None


def test_in_repair_window() -> None:
    assert kf.in_repair_window(2021, 2025)
    assert kf.in_repair_window("2025", 2025)
    assert not kf.in_repair_window(2020, 2025)
    assert not kf.in_repair_window("Total", 2025)


def test_key_facts_values(facts_backend, cut) -> None:
    facts = kf.key_facts(2026, cut)
    values = {f["id"]: f["value"] for f in facts}
    assert len(values) == len(facts) == 34
    assert values["margin_2017_22"] == 25.12
    assert values["svc_sales_share"] == 30.0
    assert values["svc_margin_share"] == 75.0
    assert (values["big_deals_count_ly"], values["big_deals_net_ly"], values["big_deals_margin_pct_ly"]) == (
        2,
        10000.0,
        10.0,
    )
    assert (values["ytd_gap"], values["ytd_gap_big_deals"], values["ytd_gap_big_share"]) == (0.0, 0.0, None)
    assert (values["contract_customers_2020"], values["contract_customers_ly"]) == (0, 12)
    assert (values["new_customers_2018"], values["new_customers_ly"]) == (50, 30)
    assert (values["margin_companies"], values["margin_private"], values["margin_public"]) == (20.0, 30.0, 10.0)
    assert (values["champions_count"], values["cant_lose_net"]) == (5, 300.0)
    assert (values["faial_share"], values["pico_share"]) == (70.0, 20.0)
    assert values["repairs_no_value_pct"] == 25.0
    assert (values["repairs_conversion_pct"], values["uneconomical_bought_pct"]) == (10.0, 25.0)
    assert (values["repairs_peak_year"], values["repairs_peak"], values["repairs_ly"]) == (2019, 900, 400)
    assert (values["open_repairs"], values["open_repairs_1y"]) == (2, 1)
    assert (values["freight_absorbed_ly"], values["receivables_over_90"]) == (123.46, 15.0)
    assert "2017\N{EN DASH}2022" in facts[0]["description"]


def test_ytd_gap_share_when_years_differ(monkeypatch, ctx) -> None:
    answers = {2026: {"net": 80.0, "big": 10.0}, 2025: {"net": 100.0, "big": 25.0}}
    monkeypatch.setattr(db, "rows", lambda _sql, params: [answers[params[0]]])
    gap, big_gap, share = kf.ytd_gap_facts(ctx)
    assert (gap["value"], big_gap["value"], share["value"]) == (20.0, 15.0, 75.0)


def test_main_prints_facts(facts_backend, capsys) -> None:
    facts_backend.sql.insert(0, ("MAX(doc_date)", [{"d": "2026-03-07"}]))
    kf.main()
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 34
    assert lines[0].split()[0] == "margin_2017_22"

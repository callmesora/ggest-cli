"""Tests for dashboards.export_datasets: core dataset builders, registry and the export entry point."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from bi import metrics
from dashboards import export_datasets as ex
from dashboards.common import Dataset

ROOT = Path(__file__).resolve().parents[2]
LIVE_DB = ROOT / "data" / "data.sqlite"


def test_registry_names_are_unique_and_complete() -> None:
    names = [d.name for d in ex.ALL_DATASETS]
    assert len(names) == len(set(names)) == 52
    assert names[0] == "sales_yearly"
    assert names[-1] == "data_quality"
    assert all(d.description for d in ex.ALL_DATASETS)


def test_ytd_comparison(monkeypatch, ctx) -> None:
    monkeypatch.setattr(metrics, "kpis", lambda s, e: {"net": f"{s}..{e}"})
    out = ex.ytd_comparison(ctx)
    assert out == [
        {
            "which": "current",
            "period": "2026 até 07/03",
            "start": "2026-01-01",
            "end": "2026-03-07",
            "net": "2026-01-01..2026-03-07",
        },
        {
            "which": "previous",
            "period": "2025 até 07/03",
            "start": "2025-01-01",
            "end": "2025-03-07",
            "net": "2025-01-01..2025-03-07",
        },
    ]


def test_repairs_yearly(monkeypatch, ctx) -> None:
    monkeypatch.setattr(
        metrics,
        "repairs_over_time",
        lambda _g: [{"period": 2024, "repairs": 5, "customers": 4}, {"period": 2023, "repairs": 2, "customers": 2}],
    )
    monkeypatch.setattr(metrics, "repair_revenue", lambda _g: [{"period": 2024, "service_net": 10.0}])
    assert ex.repairs_yearly(ctx) == [
        {"year": 2023, "repairs": 2, "customers": 2, "service_net": None},
        {"year": 2024, "repairs": 5, "customers": 4, "service_net": 10.0},
    ]


def test_forecast_params(fake, ctx) -> None:
    fake.saved["management_year_end_forecast"] = [{"x": 1}]
    assert ex.forecast(ctx) == [{"x": 1}]
    assert fake.calls[0][1] == {"year": 2026, "cutoff": "03-07", "ref_from": 2022, "ref_to": 2024}


def test_segments_yearly(fake, ctx) -> None:
    fake.saved["customers_segment_by_year"] = [
        {"year": 2025, "segment": "consumidor_final", "net_sales": 10.0},
        {"year": 2025, "segment": "empresa", "net_sales": None},
        {"year": 2024, "segment": "outro", "net_sales": 1.0},
    ]
    assert ex.segments_yearly(ctx) == [
        {"year": 2024, "particular": 0, "empresa": 0, "publico": 0, "associativo": 0, "outro": 1.0},
        {"year": 2025, "particular": 10.0, "empresa": 0, "publico": 0, "associativo": 0},
    ]


def test_recurring_yearly(fake, ctx) -> None:
    fake.saved["sales_recurring_revenue_by_year"] = [
        {"year": 2025, "stream": "gGest contrato anual actualizacao", "net_sales": 100.0, "customers": 7},
        {"year": 2025, "stream": "gGest licenca vitalicia (NAO recorrente)", "net_sales": 50.0, "customers": 1},
        {"year": 2025, "stream": "Something else", "net_sales": 5.5, "customers": 2},
        {"year": 2024, "stream": "Alojamento e dominios", "net_sales": 3.0, "customers": 1},
    ]
    y2024, y2025 = ex.recurring_yearly(ctx)
    assert y2024["contract_customers"] == 0
    assert y2024["recurring_total"] == 3.0
    assert y2025 == {
        "year": 2025,
        "contracts": 100.0,
        "subscriptions": 0,
        "year_end": 0,
        "hosting": 0,
        "other": 5.5,
        "lifetime": 50.0,
        "contract_customers": 7,
        "recurring_total": 105.5,
    }


def test_stock_split(fake, ctx) -> None:
    fake.saved["finance_stock_value_by_group"] = [{"group_name": f"G{i}"} for i in range(14)] + [
        {"group_name": "TOTAL"}
    ]
    assert len(ex.stock_by_group(ctx)) == 12
    assert ex.stock_total(ctx) == [{"group_name": "TOTAL"}]


def test_simple_registry_entries(fake, monkeypatch, ctx) -> None:
    monkeypatch.setattr(metrics, "sales_over_time", lambda _g: [{"period": "2016-12"}, {"period": "2017-01"}])
    monkeypatch.setattr(
        metrics, "sales_by_weekday_hour", lambda start: [{"hour": 0, "s": start}, {"hour": 9, "s": start}]
    )
    fake.saved["finance_receivables_aging"] = [{"bucket": "1-30"}, {"bucket": "Total"}]
    fake.saved["finance_profit_and_loss_by_year"] = [dict.fromkeys((*ex.PNL_COLUMNS, "extra"), 1)]
    fake.saved["sales_business_lines"] = [{"n": i} for i in range(20)]
    build = {d.name: d.build for d in ex.CORE_DATASETS}
    assert build["sales_monthly"](ctx) == [{"period": "2017-01"}]
    assert build["weekday_hour_3y"](ctx) == [{"hour": 9, "s": "2023-01-01"}]
    assert build["receivables_aging"](ctx) == [{"bucket": "1-30"}]
    assert list(build["pnl_yearly"](ctx)[0]) == list(ex.PNL_COLUMNS)
    assert len(build["business_lines_3y"](ctx)) == 12
    assert fake.calls[-1][1] == {"start": "2023-01-01", "end": "2025-12-31"}


def test_meta(ctx) -> None:
    meta = ex.meta(ctx)
    assert meta["data_until"] == "2026-03-07"
    assert meta["this_year"] == 2026
    assert meta["last3_from"] == "2023-01-01"
    assert len(meta["exported_at"]) == len("2026-01-01")


def test_export_all_writes_datasets_and_meta(tmp_path, ctx, capsys) -> None:
    out = tmp_path / "nested" / "out"
    datasets = [Dataset("alpha", "demo", lambda c: [{"year": c.this_year}])]
    assert ex.export_all(out, ctx=ctx, datasets=datasets) is ctx
    assert json.loads((out / "alpha.json").read_text(encoding="utf-8")) == [{"year": 2026}]
    assert json.loads((out / "_meta.json").read_text(encoding="utf-8"))["data_until"] == "2026-03-07"
    assert "data until 2026-03-07" in capsys.readouterr().out


def test_main_passes_out_folder(monkeypatch, tmp_path) -> None:
    seen = []
    monkeypatch.setattr(ex, "export_all", seen.append)
    assert ex.main(["--out", str(tmp_path)]) == 0
    assert seen == [tmp_path]


@pytest.mark.livedb
@pytest.mark.skipif(not LIVE_DB.exists(), reason="data/data.sqlite not present")
def test_full_export_against_live_db(tmp_path) -> None:
    """Export everything from the real database; when the snapshot matches the published files, compare bytes."""
    ctx = ex.export_all(tmp_path)
    written = sorted(p.name for p in tmp_path.glob("*.json"))
    assert written == sorted([f"{d.name}.json" for d in ex.ALL_DATASETS] + ["_meta.json"])
    for name in written:
        json.loads((tmp_path / name).read_text(encoding="utf-8"))
    published_meta = ex.DEFAULT_OUT / "_meta.json"
    if published_meta.exists() and json.loads(published_meta.read_text(encoding="utf-8"))["data_until"] == ctx.last:
        changed = [
            d.name
            for d in ex.ALL_DATASETS
            if (tmp_path / f"{d.name}.json").read_bytes() != (ex.DEFAULT_OUT / f"{d.name}.json").read_bytes()
        ]
        assert changed == []

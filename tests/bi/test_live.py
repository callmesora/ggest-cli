"""Checks on the real database (skipped when data/data.sqlite is absent). Asserts shape, never business figures."""

from pathlib import Path

import pytest

from bi import metrics, saved

pytestmark = [pytest.mark.livedb, pytest.mark.usefixtures("live_db")]


def test_every_saved_query_runs() -> None:
    failed = [r for r in saved.check() if r["error"]]
    assert failed == []


def test_views_exist() -> None:
    views = {v["name"] for v in metrics.describe()}
    assert {"sales_docs", "customer_dim", "repairs", "receivable_docs"} <= views


def test_snapshot_and_growth(live_db: Path) -> None:
    snapshot = saved.run_saved_query("management_kpi_snapshot")
    assert snapshot
    years = metrics.year_over_year()
    assert years[-1]["basis"] in {"full year"} or years[-1]["basis"].startswith("year to date")

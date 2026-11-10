"""Every registered tool against the synthetic database, plus the saved-query library and the registry."""

from pathlib import Path
from typing import Any

import pytest

from bi import metrics, saved
from bi.metrics import explore
from bi.registry import TOOLS, params

pytestmark = pytest.mark.usefixtures("fake_db")


# --- sales ---------------------------------------------------------------------------------------------


def test_sales_over_time_by_year() -> None:
    rows = {r["period"]: r for r in metrics.sales_over_time("year")}
    assert rows[2025]["net_sales"] == 2600.0
    assert rows[2025]["documents"] == 4
    assert rows[2024]["services_net"] == 100.0


def test_kpis_for_a_period() -> None:
    k = metrics.kpis("2025-01-01", "2025-12-31")
    assert (k["net_sales"], k["invoices"], k["repairs_opened"]) == (2600.0, 3, 1)
    assert k["avg_invoice_net"] == round(2600 / 3, 2)
    assert metrics.kpis("1990-01-01", "1990-12-31")["avg_invoice_net"] is None


def test_top_products_by_margin_and_kind() -> None:
    assert metrics.top_products(by="margin", limit=1)[0]["item_code"] == "PC1"
    services = metrics.top_products(kind="service")
    assert [r["item_code"] for r in services] == ["SVC"]
    assert services[0]["description"] == "Labour"  # catalogue description wins


def test_sales_by_category_shares() -> None:
    rows = metrics.sales_by_category("kind")
    assert sum(r["share_pct"] for r in rows) == pytest.approx(100)


def test_year_over_year_partial_current_year() -> None:
    rows = metrics.year_over_year()
    assert [r["period"] for r in rows] == [2024, 2025, 2026]
    assert rows[1]["growth_pct"] == round(100 * (2600 / 1100 - 1), 1)
    assert rows[2]["basis"].startswith("year to date")
    # 2026 to 03-01 = 1050 vs 2025 to 03-01 = 2400
    assert rows[2]["growth_pct"] == round(100 * (1050 / 2400 - 1), 1)
    assert [r["period"] for r in metrics.year_over_year(start_year=2025, end_year=2025)] == [2025]


def test_product_profile_exact_ambiguous_missing() -> None:
    assert metrics.product_profile("PC1")["sales_by_year"][0]["year"] == 2024
    assert "ambiguous" in metrics.product_profile("desktop")
    assert metrics.product_profile("Ink cartridge")["item_code"] == "INK"
    assert "error" in metrics.product_profile("zzz")


def test_sales_by_weekday_hour() -> None:
    rows = metrics.sales_by_weekday_hour()
    assert rows[0]["weekday_name"] == "Tue"


# --- customers -----------------------------------------------------------------------------------------


def test_top_customers_excludes_walk_in_by_default() -> None:
    codes = [r["customer_code"] for r in metrics.top_customers()]
    assert "WALK" not in codes
    assert codes[0] == "C1"
    assert "WALK" in [r["customer_code"] for r in metrics.top_customers(include_walk_in=True)]


def test_top_customers_by_segment() -> None:
    rows = metrics.top_customers(segment="particular", by="invoices")
    assert [r["customer_code"] for r in rows] == ["C2"]
    assert rows[0]["repair_orders_this_code_all_time"] == 2


def test_customer_concentration() -> None:
    out = metrics.customer_concentration()
    assert out["customers"] == 4
    assert out["top100_share_pct"] == 100.0


def test_customer_profile() -> None:
    c = metrics.customer_profile("C2")
    assert c["repairs"]["total"] == 2
    assert c["recent_repairs"][0]["repair_id"] == "OSA 2026/1"
    assert "ambiguous" in metrics.customer_profile("alpha")
    assert metrics.customer_profile("500000003")["customer_code"] == "C3"
    assert metrics.customer_profile("nobody")["error"].startswith("no customer")


def test_dormant_customers() -> None:
    rows = metrics.dormant_customers(min_net=100, inactive_days=200)
    assert [r["customer_code"] for r in rows] == ["C3"]


# --- repairs and purchases -----------------------------------------------------------------------------


def test_repairs_over_time_and_breakdowns() -> None:
    assert metrics.repairs_over_time()[1] == {"period": 2026, "repairs": 1, "not_closed": 1, "customers": 1}
    techs = {r["category"] for r in metrics.repairs_breakdown("technician")}
    assert techs == {"Tech One", "(não registado)"}
    assert metrics.repairs_breakdown("brand")[0]["share_pct"] == 100.0


def test_repair_turnaround_and_revenue() -> None:
    assert metrics.repair_turnaround()[0]["within_1_day"] == 1
    revenue = {r["period"]: r for r in metrics.repair_revenue()}
    assert revenue[2026]["billed_from_repair_orders"] == 150.0
    assert revenue[2026]["repairs_opened"] == 1
    assert metrics.repair_revenue("month")[0]["period"] == "2024-06"


def test_common_faults_delegates_to_the_saved_query(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict[str, Any] = {}
    monkeypatch.setattr(saved, "run_saved_query", lambda name, p: seen.update(name=name, p=p) or [])
    metrics.common_faults(start="2025-01-01", grain="year")
    assert seen == {"name": "repairs_fault_categories",
                    "p": {"grain": "year", "equipment_group": "all", "start": "2025-01-01"}}  # fmt: skip


def test_purchases() -> None:
    assert metrics.purchases_by_supplier()[0] == {
        "supplier_code": "S1", "supplier": "Supplier One", "net_purchases": 1500.0, "documents": 1,
        "last_purchase": "2025-01-05"}  # fmt: skip
    by_year = {r["period"]: r for r in metrics.purchases_vs_sales()}
    assert by_year[2025]["net_purchases"] == 1600.0
    assert by_year[2024]["net_purchases"] is None


# --- exploration ---------------------------------------------------------------------------------------


def test_describe() -> None:
    assert {"name": "sales_by_year_v", "type": "view"} in metrics.describe()
    assert "sample" in metrics.describe("customers")
    assert "error" in metrics.describe("utilizadores")
    hidden = metrics.describe("contacts")
    assert hidden["columns"] == "code"
    with pytest.raises(ValueError, match="no view or table"):
        metrics.describe("nothing_here")


def test_query_tool() -> None:
    assert metrics.query("SELECT COUNT(*) AS n FROM items")["rows"] == [[4]]


def test_data_dictionary_topics(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "domains").mkdir()
    (tmp_path / "DATA_DICTIONARY.md").write_text("# Dict", encoding="utf-8")
    (tmp_path / "domains" / "sales.md").write_text("# Sales", encoding="utf-8")
    monkeypatch.setattr(explore, "DOCS", tmp_path)
    assert metrics.data_dictionary().startswith("# Dict")
    assert "sales" in metrics.data_dictionary()
    assert metrics.data_dictionary("sales") == "# Sales"
    with pytest.raises(ValueError, match="unknown topic"):
        metrics.data_dictionary("nope")


# --- saved queries -------------------------------------------------------------------------------------


@pytest.fixture
def query_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    folder = tmp_path / "queries" / "sales"
    folder.mkdir(parents=True)
    (folder / "by_year.sql").write_text(
        "-- name: test_sales_by_year\n-- description: Net sales per year since a date\n"
        "-- params: start=last_year_start, limit=10, factor=1.5\n"
        "SELECT year, SUM(net) * :factor AS v FROM sales_facts WHERE doc_date >= :start GROUP BY 1 LIMIT :limit;\n",
        encoding="utf-8",
    )
    (folder / "broken.sql").write_text("-- description: broken\nSELECT * FROM missing", encoding="utf-8")
    monkeypatch.setattr(saved, "QUERIES", tmp_path / "queries")
    return folder


@pytest.mark.parametrize(
    ("text", "value"), [("10", 10), ("-3", -3), ("1.5", 1.5), (" x ", "x"), ("2026-01-01", "2026-01-01")]
)
def test_parse_value(text: str, value: Any) -> None:
    assert saved.parse_value(text) == value


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Short one. Then more detail.", "Short one."),
        ("Sales (gross, i.e. with VAT; per year) and more", "Sales (gross, i.e. with VAT; per year) and more"),
        ("word " * 40, ("word " * 28).strip() + "…"),
    ],
)
def test_first_sentence(text: str, expected: str) -> None:
    assert saved.first_sentence(text) == expected


def test_parse_and_search(query_dir: Path) -> None:
    q = saved.parse(query_dir / "by_year.sql")
    assert q.params == {"start": "last_year_start", "limit": 10, "factor": 1.5}
    assert q.domain == "sales"
    assert not q.sql.endswith(";")
    assert saved.parse(query_dir / "broken.sql").name == "broken"
    brief = saved.saved_queries(search="per year")
    assert brief == [{"name": "test_sales_by_year", "domain": "sales", "summary": "Net sales per year since a date",
                      "params": "start=last_year_start, limit=10, factor=1.5"}]  # fmt: skip
    assert saved.saved_queries(search="per year", full=True)[0]["description"] == "Net sales per year since a date"
    assert saved.saved_queries(domain="stock") == []
    assert "SELECT" in saved.saved_queries(name="test_sales_by_year")["sql"]
    with pytest.raises(ValueError, match="unknown saved query"):
        saved.saved_queries(name="nope")


def test_run_page_resolves_words_and_reports_truncation(query_dir: Path) -> None:
    page = saved.run_page("test_sales_by_year", {"limit": 5}, limit=1)
    assert page.truncated
    assert page.rows == [{"year": 2025, "v": 3900.0}]
    assert saved.run_saved_query("test_sales_by_year", {"start": "2026-01-01"}) == [{"year": 2026, "v": 1575.0}]


def test_run_saved_query_tool_marks_cut_lists(query_dir: Path) -> None:
    out = metrics.run_saved_query("test_sales_by_year", limit=1)
    assert out["truncated"]
    assert out["note"] == explore.TRUNCATED_NOTE
    assert isinstance(metrics.run_saved_query("test_sales_by_year"), list)


def test_check_reports_each_query(query_dir: Path) -> None:
    results = {r["name"]: r for r in saved.check()}
    assert results["test_sales_by_year"]["error"] == ""
    assert "missing" in results["broken"]["error"]
    assert saved.check(domain="other") == []


# --- registry ------------------------------------------------------------------------------------------


def test_registry_reads_signatures() -> None:
    p = {x.name: x for x in params(TOOLS["top_customers"].fn)}
    assert p["by"].choices == ("net", "margin", "invoices")
    assert p["include_walk_in"].kind is bool
    assert p["segment"].default is None
    assert "date word" in p["start"].description
    assert p["start"].kind is str
    required = {x.name: x.required for x in params(TOOLS["run_saved_query"].fn)}
    assert required == {"name": True, "params": False, "limit": False}


def test_tool_call_resolves_date_words() -> None:
    assert TOOLS["kpis"].call(start="year_start", end="today")["net_sales"] == 1050.0


def test_every_tool_has_a_description() -> None:
    assert len(TOOLS) == 23
    assert all(t.description for t in TOOLS.values())

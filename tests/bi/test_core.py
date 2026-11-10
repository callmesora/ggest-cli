"""Security guard, date words, config rows, database access and rendering."""

import datetime as dt
import json
from pathlib import Path

import pytest

from bi import config, dates, db, render, security

# --- security ------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "sql",
    ["SELECT 1", "  with x as (select 1) select * from x;", "SELECT name FROM customers"],
)
def test_read_only_sql_is_allowed(sql: str) -> None:
    assert security.check_read_only(sql).lower().startswith(("select", "with"))


@pytest.mark.parametrize(
    ("sql", "message"),
    [
        ("SELECT 1; SELECT 2", "one statement"),
        ("PRAGMA table_info(x)", "only SELECT"),
        ("SELECT * FROM x WHERE 1 AND (DELETE FROM y)", "write/DDL"),
        ("SELECT * FROM utilizadores", "password"),
        ("SELECT conta_iban FROM bancos", "password"),
        ("SELECT api_token FROM x", "password"),
    ],
)
def test_unsafe_sql_is_refused(sql: str, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        security.check_read_only(sql)


@pytest.mark.parametrize(("col", "secret"), [("password", True), ("IBAN", True), ("x_iban_y", True),
                                             ("name", False), ("nif", False)])  # fmt: skip
def test_secret_columns(col: str, *, secret: bool) -> None:
    assert security.is_secret_column(col) is secret


# --- dates ---------------------------------------------------------------------------------------------


def test_words_for_a_normal_day() -> None:
    w = dates.words_for(dt.date(2026, 11, 7))
    assert w["today"] == "2026-11-07"
    assert w["today_last_year"] == "2025-11-07"
    assert (w["this_year"], w["last_year"], w["years_ago_3"]) == (2026, 2025, 2023)
    assert (w["year_start"], w["last_year_start"], w["last_year_end"]) == ("2026-01-01", "2025-01-01", "2025-12-31")
    assert w["today_mmdd"] == "11-07"


def test_words_for_leap_day() -> None:
    assert dates.words_for(dt.date(2024, 2, 29))["today_last_year"] == "2023-02-28"


def test_resolve_uses_the_data_date(fake_db: Path) -> None:
    assert dates.resolve({"start": "year_start", "end": "today", "limit": 5, "x": "other"}) == {
        "start": "2026-01-01", "end": "2026-03-01", "limit": 5, "x": "other"}  # fmt: skip


def test_resolve_without_words_returns_the_same_object() -> None:
    args = {"start": "2024-01-01"}
    assert dates.resolve(args) is args


def test_data_date_falls_back_to_the_clock(fake_db: Path) -> None:
    with db.connect(read_only=False) as con:
        con.execute("DELETE FROM sales_docs")
    assert dates.data_date() == dt.datetime.now(dt.UTC).date()


# --- config --------------------------------------------------------------------------------------------


def test_expense_rule_any_and_all() -> None:
    any_rule = {"category": "Staff", "codes": ["43"], "name_like": ["%ss%"], "text_like": ["renda%"]}
    assert config.expense_rule_rows(0, any_rule) == [
        (0, "Staff", "43", None, None),
        (0, "Staff", None, "%ss%", None),
        (0, "Staff", None, None, "renda%"),
    ]
    all_rule = {"category": "Invest", "codes": ["1", "2"], "text_like": ["%solar%"], "all": True}
    assert config.expense_rule_rows(3, all_rule) == [
        (3, "Invest", "1", None, "%solar%"), (3, "Invest", "2", None, "%solar%")]  # fmt: skip


def test_series_and_region_rows() -> None:
    assert config.series_rows([{"group": "Corner", "prefixes": ["CH", "CX"]}]) == [(0, "CH", "Corner"),
                                                                                   (0, "CX", "Corner")]  # fmt: skip
    regions = [{"region": "Home", "postal_ranges": [[9900, 9904]], "locality_like": ["%town%"]}]
    assert config.region_rows(regions) == [(0, "Home", 9900, 9904, None), (0, "Home", None, None, "%town%")]


def test_apply_writes_defaults_and_overrides(fake_db: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    own = tmp_path / "own.json"
    own.write_text(json.dumps({"company_name": "Test Co", "_comment": "ignored", "internal_doc_types": ["X"],
                               "series_groups": [{"group": "Web", "prefixes": ["W"]}]}), encoding="utf-8")  # fmt: skip
    monkeypatch.setenv("GGEST_CONFIG", str(own))
    assert config.apply() == {"config_file": str(own), "company_name": "Test Co"}
    cfg = db.rows("SELECT key, value FROM _bi_config")
    assert {"key": "internal_doc_types", "value": "X"} in cfg
    assert not any(r["key"] == "_comment" for r in cfg)
    assert db.rows("SELECT * FROM _bi_series_groups") == [{"priority": 0, "series_prefix": "W", "series_group": "Web"}]
    assert db.rows("SELECT COUNT(*) AS n FROM _bi_expense_rules")[0]["n"] > 0


def test_config_path_next_to_the_database(fake_db: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GGEST_CONFIG", raising=False)
    assert config.path() is None
    (fake_db.parent / "ggest.json").write_text("{}", encoding="utf-8")
    assert config.path() == fake_db.parent / "ggest.json"


# --- db ------------------------------------------------------------------------------------------------


def test_db_path_from_environment(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    db.set_db(None)
    monkeypatch.setenv("GGEST_DB", str(tmp_path / "x.sqlite"))
    assert db.db_path() == tmp_path / "x.sqlite"
    monkeypatch.delenv("GGEST_DB")
    monkeypatch.delenv("INFORBYTE_DB", raising=False)
    assert db.db_path() == db.PROJECT / "data" / "data.sqlite"


def test_missing_database(tmp_path: Path) -> None:
    db.set_db(tmp_path / "nope.sqlite")
    try:
        with pytest.raises(FileNotFoundError, match="database not found"):
            db.rows("SELECT 1")
    finally:
        db.set_db(None)


def test_rows_and_limit(fake_db: Path) -> None:
    assert len(db.rows("SELECT * FROM customers", limit=2)) == 2
    assert db.rows("SELECT name FROM customers WHERE customer_code = ?", ("C1",)) == [{"name": "Alpha Lda"}]


def test_read_only_connection_cannot_write(fake_db: Path) -> None:
    with db.reading() as con, pytest.raises(Exception, match="readonly"):
        con.execute("DELETE FROM customers")


def test_safe_query(fake_db: Path) -> None:
    out = db.safe_query("SELECT customer_code FROM customers ORDER BY 1", limit=2)
    assert out == {"columns": ["customer_code"], "rows": [["C1"], ["C2"]], "truncated": True}
    with pytest.raises(ValueError, match="password"):
        db.safe_query("SELECT * FROM contacts")  # a credential column only visible in the result


def test_build_views_from_one_file(fake_db: Path, tmp_path: Path) -> None:
    sql = tmp_path / "v.sql"
    sql.write_text("DROP VIEW IF EXISTS v_test; CREATE VIEW v_test AS SELECT 1 AS one;", encoding="utf-8")
    assert "v_test" in db.build_views(sql)
    bad = tmp_path / "bad.sql"
    bad.write_text("CREATE VIEW broken AS SELECT * FROM missing_table; SELECT * FROM broken;", encoding="utf-8")
    with pytest.raises(RuntimeError, match=r"bad\.sql"):
        db.build_views(bad)


def test_build_views_drops_legacy_views(fake_db: Path, tmp_path: Path) -> None:
    with db.connect(read_only=False) as con:
        con.execute("CREATE VIEW product_cost_ratios AS SELECT 1")
    sql = tmp_path / "v.sql"
    sql.write_text("SELECT 1;", encoding="utf-8")
    assert "product_cost_ratios" not in db.build_views(sql)


# --- render --------------------------------------------------------------------------------------------


def test_table_formats_numbers_and_blanks() -> None:
    text = render.table([{"name": "a", "net": 1234.5, "n": None}, {"name": "b" * 50, "net": 2.0, "n": 3}])
    lines = text.splitlines()
    assert lines[0].split() == ["name", "net", "n"]
    assert "1,234.50" in lines[2]
    assert len(lines[3].split()[0]) == render.MAX_WIDTH


@pytest.mark.parametrize(
    ("data", "expected"),
    [("plain text", "plain text"), ([], "(no rows)"), ({"a": 1}, '{\n  "a": 1\n}')],
)
def test_table_other_shapes(data: object, expected: str) -> None:
    assert render.table(data) == expected


def test_table_from_query_and_cut_results() -> None:
    assert "x" in render.table({"columns": ["x"], "rows": [[1]], "truncated": False})
    cut = {"rows": [{"y": 2}], "truncated": True, "note": "more"}
    assert render.table(cut).splitlines()[0].strip() == "y"
    assert render.is_truncated(cut)
    assert not render.is_truncated([1])


def test_query_list() -> None:
    text = render.query_list([{"name": "q", "domain": "d", "params": "", "summary": "what"}])
    assert "q  [d]" in text
    assert "    what" in text
    assert "1 saved queries" in text.splitlines()[-1]
    assert "full text" in render.query_list([{"name": "q", "domain": "d", "params": {}, "description": "full text"}])


def test_compact_turns_records_into_columns_and_rows() -> None:
    assert render.compact([{"a": 1, "b": 2}, {"a": 3, "c": 4}]) == {
        "columns": ["a", "b", "c"], "rows": [[1, 2, None], [3, None, 4]]}  # fmt: skip
    profile = {"name": "x", "sales": [{"year": 2025, "net": 1.0}], "tags": [], "n": 3}
    assert render.compact(profile) == {"name": "x", "sales": {"columns": ["year", "net"], "rows": [[2025, 1.0]]},
                                       "tags": [], "n": 3}  # fmt: skip
    cut = {"rows": [{"y": 1}], "truncated": True, "note": "more"}
    assert render.compact(cut) == {"columns": ["y"], "rows": [[1]], "truncated": True, "note": "more"}
    assert render.compact("text") == "text"

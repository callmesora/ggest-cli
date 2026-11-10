"""Tests for dashboards.common (pure helpers, no database)."""

from __future__ import annotations

import json
from datetime import date

from dashboards import common
from dashboards.common import Context


def test_context_from_last() -> None:
    ctx = Context.from_last("2026-03-07")
    assert ctx.cut == date(2026, 3, 7)
    assert (ctx.this_year, ctx.ly, ctx.md, ctx.last3, ctx.last) == (2026, 2025, "03-07", "2023-01-01", "2026-03-07")


def test_context_load_reads_last_document(fake) -> None:
    fake.sql.append(("MAX(doc_date)", [{"d": "2025-12-30"}]))
    assert Context.load() == Context(last="2025-12-30", cut=date(2025, 12, 30), this_year=2025)


def test_run_saved_delegates(fake) -> None:
    fake.saved["q"] = [{"a": 1}]
    assert common.run_saved("q", {"x": 1}, limit=7) == [{"a": 1}]
    assert fake.calls == [("q", {"x": 1}, {"limit": 7})]


def test_clean_drops_unencodable_characters() -> None:
    assert common.clean("ab\udcffc�") == "ab?c"
    assert common.clean(5) == 5
    assert common.clean(None) is None


def test_pick_and_clean_rows() -> None:
    rows = [{"a": 1, "b": "x�", "c": 3}]
    assert common.pick(rows, ["c", "a"]) == [{"c": 3, "a": 1}]
    assert list(common.pick(rows, ["c", "a"])[0]) == ["c", "a"]
    assert common.clean_rows(rows, ["b"]) == [{"b": "x"}]
    assert common.clean_rows(rows) == [{"a": 1, "b": "x", "c": 3}]


def test_by_key_col_sum_sorted_values_is_year() -> None:
    rows = [{"k": 2, "v": 1}, {"k": 1, "v": 2}, {"k": 2, "v": 3}]
    assert common.by_key(rows, "k") == {2: {"k": 2, "v": 3}, 1: {"k": 1, "v": 2}}
    assert common.col_sum(rows, "v") == 6
    assert common.sorted_values({"b": {"n": 2}, "a": {"n": 1}}) == [{"n": 1}, {"n": 2}]
    assert common.is_year(2024)
    assert common.is_year("2024")
    assert not common.is_year("Total")


def test_add_rounded() -> None:
    row = {"a": 0.1}
    common.add_rounded(row, "a", 0.2)
    common.add_rounded(row, "b", None)
    assert row == {"a": 0.3, "b": 0}


def test_pivot_sum_default_head_and_skip() -> None:
    rows = [
        {"year": 2025, "col": "x", "net_sales": 1.005},
        {"year": 2024, "col": "y", "net_sales": 2},
        {"year": 2025, "col": "x", "net_sales": None},
        {"year": 2023, "col": None, "net_sales": 9},
        {"year": 2025, "col": "z", "net_sales": 1},
    ]
    out = common.pivot_sum(rows, "year", ("x", "y"), lambda r: r["col"])
    assert out == [{"year": 2024, "x": 0, "y": 2}, {"year": 2025, "x": round(1.005, 2), "y": 0, "z": 1}]
    assert list(out[0]) == ["year", "x", "y"]


def test_pivot_sum_custom_head_and_value() -> None:
    rows = [{"period": "2024", "n": 3}, {"period": "2024", "n": 4}]
    out = common.pivot_sum(
        rows, "period", ["n_total"], lambda _r: "n_total", value="n", head=lambda r: {"y": int(r["period"])}
    )
    assert out == [{"y": 2024, "n_total": 7}]


def test_save_dataset_writes_json_and_prints(tmp_path, capsys) -> None:
    common.save_dataset(tmp_path, "demo", [{"name": "Ação", "d": date(2026, 1, 2)}])
    common.save_dataset(tmp_path, "one", {"a": 1})
    text = (tmp_path / "demo.json").read_text(encoding="utf-8")
    assert json.loads(text) == [{"name": "Ação", "d": "2026-01-02"}]
    assert "Ação" in text  # ensure_ascii=False
    out = capsys.readouterr().out.splitlines()
    assert out[0].split() == ["demo", "1", "rows"]
    assert out[1].split() == ["one", "1", "rows"]

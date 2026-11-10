"""The click CLI and the FastMCP server, end to end on the synthetic database."""

import asyncio
import json
from pathlib import Path

import pytest
from click.testing import CliRunner
from fastmcp import Client

from bi import cli, saved
from bi.mcp_server import build_server
from bi.registry import TOOLS


@pytest.fixture
def run(fake_db: Path):
    runner = CliRunner()

    def invoke(*args: str):
        return runner.invoke(cli.cli, list(args))

    return invoke


# --- CLI -----------------------------------------------------------------------------------------------


def test_list(run) -> None:
    result = run("list")
    assert result.exit_code == 0
    assert len(result.output.splitlines()) == len(TOOLS)


def test_tool_json_and_table(run) -> None:
    out = run("kpis", "--start", "2025-01-01", "--end", "2025-12-31", "--json")
    assert json.loads(out.output)["net_sales"] == 2600.0
    table = run("top-products", "--by", "margin", "--limit", "1")
    assert table.exit_code == 0
    assert "PC1" in table.output


def test_dash_and_underscore_names(run) -> None:
    assert run("year_over_year", "--start_year", "2025").exit_code == 0
    assert run("year-over-year", "--start-year", "2025").exit_code == 0


def test_bad_choice_and_missing_required(run) -> None:
    assert run("top_products", "--by", "colour").exit_code == 2
    assert run("customer_profile").exit_code == 2


def test_user_errors_exit_2(run) -> None:
    sql_error = run("query", "--sql", "SELECT nope FROM items")
    assert sql_error.exit_code == 2
    assert "describe" in sql_error.output
    assert run("query", "--sql", "DELETE FROM items").exit_code == 2
    assert run("run_saved_query", "--name", "nope").exit_code == 2


@pytest.mark.parametrize(
    ("text", "expected"),
    [('{"start": "2025-01-01"}', {"start": "2025-01-01"}), ("start=2025-01-01,limit=5", {"start": "2025-01-01",
     "limit": 5}), ("{start:2025-01-01}", {"start": "2025-01-01"}), ("", {})],
)  # fmt: skip
def test_parse_params(text: str, expected: dict) -> None:
    assert cli.parse_params(text) == expected


@pytest.mark.parametrize("text", ["oops", "[1, 2]"])
def test_parse_params_rejects(text: str) -> None:
    with pytest.raises(ValueError, match="params"):
        cli.parse_params(text)


def test_params_option_and_truncation_note(run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "q" / "sales").mkdir(parents=True)
    (tmp_path / "q" / "sales" / "a.sql").write_text(
        "-- name: years\n-- description: years\n-- params: since=2000-01-01\n"
        "SELECT DISTINCT year FROM sales_facts WHERE doc_date >= :since ORDER BY 1", encoding="utf-8")  # fmt: skip
    monkeypatch.setattr(saved, "QUERIES", tmp_path / "q")
    cut = run("run_saved_query", "--name", "years", "--params", "since=2025-01-01", "--limit", "1")
    assert "2025" in cut.output
    assert "NOTE: more rows exist" in cut.output
    assert run("run_saved_query", "--name", "years", "--params", "bad").exit_code == 2
    listing = run("saved_queries", "--search", "years")
    assert "1 saved queries" in listing.output
    checked = run("check-queries")
    assert checked.exit_code == 0
    assert "1 queries, 0 failed" in checked.output


def test_check_queries_fails_on_errors(run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "q").mkdir()
    (tmp_path / "q" / "bad.sql").write_text("SELECT * FROM missing", encoding="utf-8")
    monkeypatch.setattr(saved, "QUERIES", tmp_path / "q")
    assert run("check_queries").exit_code == 1


def test_build_views_and_db_option(fake_db: Path, tmp_path: Path) -> None:
    sql = tmp_path / "v.sql"
    sql.write_text("CREATE VIEW IF NOT EXISTS v_x AS SELECT 1;", encoding="utf-8")
    result = CliRunner().invoke(cli.cli, ["--db", str(fake_db), "build-views", "--file", str(sql)])
    assert result.exit_code == 0
    assert "v_x" in result.output


# --- MCP -----------------------------------------------------------------------------------------------


def _mcp(coro_fn):
    async def go():
        async with Client(build_server()) as client:
            return await coro_fn(client)

    return asyncio.run(go())


def test_mcp_lists_every_tool_read_only(fake_db: Path) -> None:
    tools = _mcp(lambda c: c.list_tools())
    assert {t.name for t in tools} == set(TOOLS)
    assert all(t.annotations.readOnlyHint for t in tools)
    schema = next(t for t in tools if t.name == "top_products").inputSchema
    assert schema["properties"]["by"]["enum"] == ["net", "margin", "qty"]


def test_mcp_call_and_errors(fake_db: Path) -> None:
    ok = _mcp(lambda c: c.call_tool("kpis", {"start": "year_start", "end": "today"}))
    assert json.loads(ok.content[0].text)["net_sales"] == 1050.0
    table = _mcp(lambda c: c.call_tool("top_products", {"limit": 2}))
    out = json.loads(table.content[0].text)
    assert out["columns"][0] == "item_code"
    assert out["rows"][0][0] == "PC1"
    refused = _mcp(lambda c: c.call_tool("query", {"sql": "SELECT * FROM utilizadores"}, raise_on_error=False))
    assert refused.is_error
    assert "password" in refused.content[0].text

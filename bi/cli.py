"""Command line: ggest [--db path/to/data.sqlite] <command> [--option value ...] [--json]

Every tool in the registry is a command (`ggest list` shows them); its options come from the function signature.
Command and option names accept '_' or '-' (top_products = top-products, --start_year = --start-year).

Examples:

\b
  ggest build-views                        (all views; --file bi/sql/ext/x.sql applies one file)
  ggest check-queries --domain sales       (run every saved query, report errors and timings)
  ggest saved_queries --search "stock"
  ggest kpis --start year_start --end today
  ggest top_products --by margin --limit 10
  ggest run_saved_query --name management_change_drivers --params dim=segment
  ggest query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
"""

import json
import sqlite3
import sys
from pathlib import Path
from typing import Any

import click

from . import db, render, saved
from .metrics import TOOLS  # importing bi.metrics registers every tool
from .registry import Param, Tool, params

EXIT_USAGE = 2
_CLICK_TYPES: dict[Any, click.ParamType] = {int: click.INT, float: click.FLOAT, str: click.STRING}


class UserError(click.ClickException):
    """A problem with the request (bad parameter, unknown name, SQL error): message, exit code 2."""

    exit_code = EXIT_USAGE


class ParamsType(click.ParamType):
    """--params as JSON ('{"start": "2024-01-01"}') or key=value pairs (start=2024-01-01,limit=10); the second
    form survives shells that strip quotes (Windows PowerShell)."""

    name = "params"

    def convert(self, value: Any, param: click.Parameter | None, ctx: click.Context | None) -> dict[str, Any]:
        if isinstance(value, dict):
            return value
        try:
            return parse_params(value)
        except ValueError as e:
            self.fail(str(e), param, ctx)


def parse_params(text: str) -> dict[str, Any]:
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return dict(_pair(part) for part in text.strip("{}").split(",") if part.strip())
    if not isinstance(parsed, dict):
        raise ValueError("--params must be a JSON object or key=value pairs")  # noqa: TRY004 - shown to the user
    return parsed


def _pair(part: str) -> tuple[str, Any]:
    key, sep, value = part.partition("=") if "=" in part else part.partition(":")
    if not sep:
        raise ValueError(f"bad --params part {part.strip()!r}: use key=value")
    return key.strip().strip("\"'"), saved.parse_value(value.strip().strip("\"'"))


def option(p: Param) -> click.Option:
    """A click option for one tool parameter: --name (bool -> flag; Literal -> choice; dict -> --params)."""
    decls = [f"--{p.name}", p.name]
    if p.kind is bool:
        return click.Option(decls, is_flag=True, default=False, help=p.description or None)
    kind = click.Choice(p.choices) if p.choices else ParamsType() if p.kind is dict else _CLICK_TYPES.get(p.kind)
    if p.required:  # no default at all: click's required check treats default=None as a value
        return click.Option(decls, type=kind, required=True, help=p.description or None)
    return click.Option(decls, type=kind, default=p.default, show_default=p.default is not None,
                        help=p.description or None)  # fmt: skip


def emit(name: str, out: Any, *, as_json: bool) -> None:
    if as_json:
        click.echo(render.to_json(out))
    elif name == "saved_queries" and isinstance(out, list):
        click.echo(render.query_list(out))
    else:
        click.echo(render.table(out))
    if render.is_truncated(out):
        note = "\nNOTE: more rows exist than shown (limit reached); rerun with a higher --limit for totals."
        click.echo(note, err=as_json)


def run_tool(t: Tool, kwargs: dict[str, Any]) -> Any:
    try:
        return t.call(**{k: v for k, v in kwargs.items() if v is not None})
    except sqlite3.Error as e:
        raise UserError(f"{e}  (ggest describe --name <view> lists columns)") from e
    except (ValueError, FileNotFoundError) as e:
        raise UserError(str(e)) from e


def tool_command(t: Tool) -> click.Command:
    def callback(as_json: bool, **kwargs: Any) -> None:
        emit(t.name, run_tool(t, kwargs), as_json=as_json)

    opts = [option(p) for p in params(t.fn)]
    opts.append(click.Option(["--json", "as_json"], is_flag=True, help="print JSON"))
    return click.Command(t.name, callback=callback, params=opts, help=t.description, short_help=t.description)


class ToolGroup(click.Group):
    """Built-in commands plus one command per registered tool."""

    def list_commands(self, ctx: click.Context) -> list[str]:
        return [*super().list_commands(ctx), *TOOLS]

    def get_command(self, ctx: click.Context, cmd_name: str) -> click.Command | None:
        if cmd_name in TOOLS:
            return tool_command(TOOLS[cmd_name])
        return super().get_command(ctx, cmd_name)


def _normalize(token: str) -> str:
    return token.replace("-", "_")


@click.group(cls=ToolGroup, help=__doc__, context_settings={"token_normalize_func": _normalize})
@click.option("--db", "db_file", type=click.Path(dir_okay=False, path_type=Path), help="SQLite database to use")
def cli(db_file: Path | None) -> None:
    if db_file:
        db.set_db(db_file)


@cli.command("build_views")
@click.option("--file", "sql_file", type=click.Path(exists=True, dir_okay=False, path_type=Path))
def build_views(sql_file: Path | None) -> None:
    """(Re)create the business views; --file applies one .sql file."""
    click.echo("views: " + ", ".join(db.build_views(sql_file)))


@cli.command("check_queries")
@click.option("--domain", help="only this query folder (sales, customers, ...)")
def check_queries(domain: str | None) -> None:
    """Run every saved query with its defaults; exit code 1 when any fails."""
    results = saved.check(domain)
    click.echo(render.table(results))
    failed = [r for r in results if r["error"]]
    slowest = max((r["secs"] for r in results), default=0)
    click.echo(f"\n{len(results)} queries, {len(failed)} failed, slowest {slowest} s")
    if failed:
        sys.exit(1)


@cli.command("list")
def list_tools() -> None:
    """List the tools with a one-line description."""
    for t in TOOLS.values():
        click.echo(f"{t.name:24} {t.description}")


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    cli()

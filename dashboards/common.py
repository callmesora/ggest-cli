"""Shared pieces of the dashboard dataset exporters: export context, dataset registry entries and row helpers."""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import date
from typing import TYPE_CHECKING, Any, NamedTuple

from bi import db, saved

if TYPE_CHECKING:
    from pathlib import Path

Row = dict[str, Any]

LAST_DOC_SQL = "SELECT MAX(doc_date) AS d FROM sales_docs WHERE is_cancelled = 0"


@dataclass(frozen=True)
class Context:
    """Dates every dataset is cut at: the last sales document in the snapshot and the year it falls in."""

    last: str  # export cut-off as stored in the database (YYYY-MM-DD)
    cut: date
    this_year: int

    @classmethod
    def from_last(cls, last: str) -> Context:
        """Build the context from the cut-off date string."""
        cut = date.fromisoformat(last)
        return cls(last=last, cut=cut, this_year=cut.year)

    @classmethod
    def load(cls) -> Context:
        """Read the cut-off (last non-cancelled sales document) from the database."""
        return cls.from_last(db.rows(LAST_DOC_SQL)[0]["d"])

    @property
    def ly(self) -> int:
        """Last (complete) year."""
        return self.this_year - 1

    @property
    def md(self) -> str:
        """Cut-off month and day, MM-DD."""
        return f"{self.cut:%m-%d}"

    @property
    def last3(self) -> str:
        """Start of the 3-years-back window (1 January)."""
        return f"{self.this_year - 3}-01-01"


class Dataset(NamedTuple):
    """One dashboard dataset: file name (without .json), what it shows and the function that builds its rows."""

    name: str
    description: str
    build: Callable[[Context], Any]


def run_saved(name: str, params: Mapping[str, Any] | None = None, **kwargs: Any) -> list[Row]:
    """Run a saved query (looked up at call time, so tests can monkeypatch ``bi.saved.run_saved_query``)."""
    return saved.run_saved_query(name, params, **kwargs)


def write_json(path: Path, data: Any, **dumps_kwargs: Any) -> None:
    """Write ``data`` as JSON (UTF-8, platform newlines, as the published files have always been written)."""
    path.write_text(json.dumps(data, **dumps_kwargs), encoding="utf-8")


def save_dataset(out_dir: Path, name: str, data: Any) -> None:
    """Write one dataset file and print its row count."""
    write_json(out_dir / f"{name}.json", data, ensure_ascii=False, indent=1, default=str)
    print(f"{name:22} {len(data) if isinstance(data, list) else 1} rows")


def clean(value: Any) -> Any:
    """Drop characters that can't be written as UTF-8 (a few gGest names hold broken bytes)."""
    if isinstance(value, str):
        return value.encode("utf-8", "replace").decode("utf-8").replace("\N{REPLACEMENT CHARACTER}", "")
    return value


def pick(rows: Iterable[Mapping[str, Any]], keys: Iterable[str]) -> list[Row]:
    """Keep only ``keys`` (in that order) from each row."""
    keys = tuple(keys)
    return [{k: r[k] for k in keys} for r in rows]


def clean_rows(rows: Iterable[Mapping[str, Any]], keys: Iterable[str] | None = None) -> list[Row]:
    """Like :func:`pick` (all keys when ``keys`` is None) with every string value passed through :func:`clean`."""
    return [{k: clean(r[k]) for k in (keys or r.keys())} for r in rows]


def by_key(rows: Iterable[Mapping[str, Any]], key: str) -> dict[Any, Mapping[str, Any]]:
    """Index rows by one column (the last row wins on duplicates)."""
    return {r[key]: r for r in rows}


def col_sum(rows: Iterable[Mapping[str, Any]], key: str) -> Any:
    """Sum of one column over the rows."""
    return sum(r[key] for r in rows)


def add_rounded(row: Row, column: str, value: float | None) -> None:
    """Add ``value`` (None counts as 0) to ``row[column]``, rounding the running total to cents."""
    row[column] = round(row.get(column, 0) + (value or 0), 2)


def pivot_sum(
    rows: Iterable[Mapping[str, Any]],
    by: str,
    columns: Iterable[str],
    column_of: Callable[[Mapping[str, Any]], str | None],
    value: str = "net_sales",
    head: Callable[[Mapping[str, Any]], Row] | None = None,
) -> list[Row]:
    """Pivot long rows into one row per ``by`` value (sorted), summing ``value`` into ``column_of(row)``.

    Each output row starts with ``head(row)`` (default ``{by: row[by]}``) followed by ``columns`` at 0.
    Rows whose column is None are skipped.
    """
    columns = tuple(columns)
    table: dict[Any, Row] = {}
    for r in rows:
        column = column_of(r)
        if column is None:
            continue
        row = table.setdefault(r[by], {**(head(r) if head else {by: r[by]}), **dict.fromkeys(columns, 0)})
        add_rounded(row, column, r[value])
    return sorted_values(table)


def sorted_values(table: Mapping[Any, Row]) -> list[Row]:
    """Values of a dict, sorted by key."""
    return [table[k] for k in sorted(table)]


def is_year(period: Any) -> bool:
    """True for a period that is a plain year (saved queries add total rows with other labels)."""
    return str(period).isdigit()

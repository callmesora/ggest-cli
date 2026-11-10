"""Date words usable in any date/year parameter: they resolve against the data date, not the clock.

today = latest sales document date in the database (so an old snapshot answers as of its own date),
this_year / last_year (e.g. 2026), year_start / last_year_start / last_year_end (ISO dates),
today_last_year (same day one year earlier, for year-to-date comparisons), today_mmdd (e.g. 11-08),
years_ago_3 (e.g. 2023).
"""

import datetime as dt
from functools import cache
from typing import Any

from . import db

WORDS = (
    "today", "this_year", "last_year", "year_start", "last_year_start", "last_year_end", "today_last_year",
    "today_mmdd", "years_ago_3",
)  # fmt: skip


def words_for(today: dt.date) -> dict[str, Any]:
    """The value of every date word when the data date is `today`."""
    try:
        same_day_last_year = today.replace(year=today.year - 1)
    except ValueError:  # 29 February
        same_day_last_year = today.replace(year=today.year - 1, day=28)
    return {
        "today": today.isoformat(),
        "this_year": today.year,
        "last_year": today.year - 1,
        "year_start": f"{today.year}-01-01",
        "last_year_start": f"{today.year - 1}-01-01",
        "last_year_end": f"{today.year - 1}-12-31",
        "today_last_year": same_day_last_year.isoformat(),
        "today_mmdd": today.strftime("%m-%d"),
        "years_ago_3": today.year - 3,
    }


def data_date() -> dt.date:
    """Last sales document date in the database (not in the future); the clock date if there are no sales."""
    found = db.rows("SELECT MAX(doc_date) AS d FROM sales_docs WHERE doc_date <= date('now')")[0]["d"]
    return dt.date.fromisoformat(found[:10]) if found else dt.datetime.now(dt.UTC).date()


@cache
def _words_for_db(path: str) -> dict[str, Any]:  # noqa: ARG001 - path is the cache key
    return words_for(data_date())


def date_words() -> dict[str, Any]:
    """Date words for the current database (cached per database file)."""
    return _words_for_db(str(db.db_path()))


def has_words(values: dict[str, Any]) -> bool:
    return any(isinstance(v, str) and v in WORDS for v in values.values())


def resolve(args: dict[str, Any]) -> dict[str, Any]:
    """Replace date words in tool arguments by their values."""
    if not has_words(args):
        return args
    words = date_words()
    return {k: words.get(v, v) if isinstance(v, str) else v for k, v in args.items()}

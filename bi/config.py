"""Per-database settings: what is company-specific in a gGest database (document types created by the company,
invoice series with a special meaning, service items, expense categories, regions).

Lookup order: env GGEST_CONFIG, then `ggest.json` next to the database file, then only the defaults in
bi/config.default.json. `apply()` (run by `ggest build-views`) stores them in small `_bi_*` tables so views and
saved queries can use them. See config.example.json.
"""

import json
import os
import sqlite3
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from . import db

HERE = Path(__file__).resolve().parent
DEFAULT = HERE / "config.default.json"
SCALAR_KEYS = (
    "company_name", "home_region", "default_series_group", "default_expense_category", "no_address_label",
    "other_region_label",
)  # fmt: skip
LIST_KEYS = (
    "internal_doc_types", "internal_doc_name_like", "excluded_series_prefixes", "service_group_names",
    "service_item_codes", "product_item_codes", "service_description_like",
)  # fmt: skip
SCHEMA = """
    DROP TABLE IF EXISTS _bi_config;
    CREATE TABLE _bi_config (key TEXT, value TEXT);
    DROP TABLE IF EXISTS _bi_series_groups;
    CREATE TABLE _bi_series_groups (priority INT, series_prefix TEXT, series_group TEXT);
    DROP TABLE IF EXISTS _bi_expense_rules;
    CREATE TABLE _bi_expense_rules (priority INT, category TEXT, code TEXT, name_like TEXT, text_like TEXT);
    DROP TABLE IF EXISTS _bi_regions;
    CREATE TABLE _bi_regions (priority INT, region TEXT, postal_from INT, postal_to INT, locality_like TEXT,
                              unknown_area TEXT);
    DROP TABLE IF EXISTS _bi_areas;
    CREATE TABLE _bi_areas (priority INT, area TEXT, region TEXT, postal_from INT, postal_to INT, locality_like TEXT,
                            postal_name TEXT);
"""

Row = tuple[Any, ...]


def path() -> Path | None:
    env = os.environ.get("GGEST_CONFIG")
    if env:
        return Path(env)
    candidate = db.db_path().parent / "ggest.json"
    return candidate if candidate.exists() else None


def load() -> dict[str, Any]:
    """Defaults overridden by the database's ggest.json (keys starting with '_' are comments)."""
    cfg = json.loads(DEFAULT.read_text(encoding="utf-8"))
    override = path()
    if override:
        own = json.loads(override.read_text(encoding="utf-8"))
        cfg.update({k: v for k, v in own.items() if not k.startswith("_")})
    return cfg


def config_rows(cfg: dict[str, Any]) -> list[Row]:
    scalars = [(k, cfg.get(k, "")) for k in SCALAR_KEYS]
    return scalars + [(k, v) for k in LIST_KEYS for v in cfg.get(k, [])]


def series_rows(groups: Iterable[dict[str, Any]]) -> list[Row]:
    return [(i, prefix, g["group"]) for i, g in enumerate(groups) for prefix in g["prefixes"]]


def expense_rule_rows(priority: int, rule: dict[str, Any]) -> list[Row]:
    """One rule -> (priority, category, code, name_like, text_like) rows. all=true: code AND text must match."""
    codes, names, texts = rule.get("codes", []), rule.get("name_like", []), rule.get("text_like", [])
    if rule.get("all"):
        conditions = [(c, None, t) for c in codes or [None] for t in texts or [None]]
    else:  # any condition matches
        conditions = [(c, None, None) for c in codes] + [(None, n, None) for n in names]
        conditions += [(None, None, t) for t in texts]
    return [(priority, rule["category"], *cond) for cond in conditions]


def expense_rows(rules: Iterable[dict[str, Any]]) -> list[Row]:
    return [row for i, rule in enumerate(rules) for row in expense_rule_rows(i, rule)]


def region_rows(regions: Iterable[dict[str, Any]]) -> list[Row]:
    """(priority, region, postal_from, postal_to, locality_like, unknown_area) per postcode range or address word."""
    out: list[Row] = []
    for i, r in enumerate(regions):
        name, unknown = r["region"], r.get("unknown_area")
        out += [(i, name, lo, hi, None, unknown) for lo, hi in r.get("postal_ranges", [])]
        out += [(i, name, None, None, like, unknown) for like in r.get("locality_like", [])]
        if not r.get("postal_ranges") and not r.get("locality_like"):
            out.append((i, name, None, None, None, unknown))  # still known, e.g. for its unknown_area label
    return out


def area_rows(areas: Iterable[dict[str, Any]]) -> list[Row]:
    """(priority, area, region, postal_from, postal_to, locality_like, postal_name) per condition of each area."""
    out: list[Row] = []
    for i, a in enumerate(areas):
        name, region = a["area"], a.get("region")
        out += [(i, name, region, lo, hi, None, None) for lo, hi in a.get("postal_ranges", [])]
        out += [(i, name, region, None, None, like, None) for like in a.get("locality_like", [])]
        out += [(i, name, region, None, None, None, pn) for pn in a.get("postal_names", [])]
    return out


def apply(con: sqlite3.Connection | None = None) -> dict[str, str]:
    """Write the settings into the database (_bi_config, _bi_series_groups, _bi_expense_rules, _bi_regions,
    _bi_areas)."""
    cfg = load()
    own = con is None
    con = con or db.connect(read_only=False)
    try:
        con.executescript(SCHEMA)
        con.executemany("INSERT INTO _bi_config VALUES (?,?)", config_rows(cfg))
        con.executemany("INSERT INTO _bi_series_groups VALUES (?,?,?)", series_rows(cfg.get("series_groups", [])))
        con.executemany("INSERT INTO _bi_expense_rules VALUES (?,?,?,?,?)", expense_rows(cfg.get("expense_rules", [])))
        con.executemany("INSERT INTO _bi_regions VALUES (?,?,?,?,?,?)", region_rows(cfg.get("regions", [])))
        con.executemany("INSERT INTO _bi_areas VALUES (?,?,?,?,?,?,?)", area_rows(cfg.get("areas", [])))
        con.commit()
    finally:
        if own:
            con.close()
    return {"config_file": str(path() or "(defaults only)"), "company_name": cfg.get("company_name", "")}

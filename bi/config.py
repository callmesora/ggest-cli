"""Per-database settings: what is company-specific in a gGest database (document types created by the company,
invoice series with a special meaning, expense categories, regions).

Lookup order: env GGEST_CONFIG, then `ggest.json` next to the database file, then only the defaults in
bi/config.default.json. Settings are stored in the database as small `_bi_*` tables (by `py -m bi build-views`
or `py -m bi apply-config`) so views and saved queries can use them. See config.example.json.
"""
import json
import os
from pathlib import Path

from . import db

HERE = Path(__file__).resolve().parent
DEFAULT = HERE / "config.default.json"


def path():
    p = os.environ.get("GGEST_CONFIG")
    if p:
        return Path(p)
    p = db.db_path().parent / "ggest.json"
    return p if p.exists() else None


def load():
    cfg = json.loads(DEFAULT.read_text(encoding="utf-8"))
    p = path()
    if p:
        for k, v in json.loads(p.read_text(encoding="utf-8")).items():
            if not k.startswith("_"):
                cfg[k] = v
    return cfg


def apply(con=None):
    """Write the settings into the database (_bi_config, _bi_series_groups, _bi_expense_rules, _bi_regions)."""
    cfg = load()
    own = con is None
    con = con or db.connect(read_only=False)
    con.executescript("""
        DROP TABLE IF EXISTS _bi_config;
        CREATE TABLE _bi_config (key TEXT, value TEXT);
        DROP TABLE IF EXISTS _bi_series_groups;
        CREATE TABLE _bi_series_groups (priority INT, series_prefix TEXT, series_group TEXT);
        DROP TABLE IF EXISTS _bi_expense_rules;
        CREATE TABLE _bi_expense_rules (priority INT, category TEXT, code TEXT, name_like TEXT, text_like TEXT);
        DROP TABLE IF EXISTS _bi_regions;
        CREATE TABLE _bi_regions (priority INT, region TEXT, postal_from INT, postal_to INT, locality_like TEXT);
    """)
    for k in ("company_name", "home_region", "default_series_group", "default_expense_category"):
        con.execute("INSERT INTO _bi_config VALUES (?,?)", (k, cfg.get(k, "")))
    for k in ("internal_doc_types", "internal_doc_name_like", "excluded_series_prefixes", "service_group_names",
              "service_item_codes", "product_item_codes", "service_description_like"):
        for v in cfg.get(k, []):
            con.execute("INSERT INTO _bi_config VALUES (?,?)", (k, v))
    for i, g in enumerate(cfg.get("series_groups", [])):
        for pre in g["prefixes"]:
            con.execute("INSERT INTO _bi_series_groups VALUES (?,?,?)", (i, pre, g["group"]))
    for i, r in enumerate(cfg.get("expense_rules", [])):
        codes, names, texts = r.get("codes", []), r.get("name_like", []), r.get("text_like", [])
        if r.get("all"):        # code AND text must both match
            rows = [(c, None, t) for c in codes or [None] for t in texts or [None]]
        else:                   # any condition matches
            rows = [(c, None, None) for c in codes] + [(None, n, None) for n in names] + [(None, None, t) for t in texts]
        for c, n, t in rows:
            con.execute("INSERT INTO _bi_expense_rules VALUES (?,?,?,?,?)", (i, r["category"], c, n, t))
    for i, r in enumerate(cfg.get("regions", [])):
        for a, b in r.get("postal_ranges", []):
            con.execute("INSERT INTO _bi_regions VALUES (?,?,?,?,NULL)", (i, r["region"], a, b))
        for loc in r.get("locality_like", []):
            con.execute("INSERT INTO _bi_regions VALUES (?,?,NULL,NULL,?)", (i, r["region"], loc))
    con.commit()
    if own:
        con.close()
    return {"config_file": str(path() or "(defaults only)"), "company_name": cfg.get("company_name", "")}

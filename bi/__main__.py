"""Command line: py -m bi [--db path/to/data.sqlite] <tool> [--param value ...] [--json]

Examples:
  py -m bi build-views                      (all views; --file bi/sql/ext/x.sql applies one file)
  py -m bi check-queries [--domain sales]   (run every saved query, report errors and timings)
  py -m bi saved_queries --search "stock"
  py -m bi kpis --start 2025-01-01 --end 2025-12-31
  py -m bi top_products --by margin --limit 10
  py -m bi customer_profile --query "<part of a name>"
  py -m bi query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
  py -m bi list
"""
import argparse
import json
import sqlite3
import sys

from . import db, metrics, saved


def parse_params(text):
    """--params as JSON ('{"start": "2024-01-01"}') or as key=value pairs (start=2024-01-01,limit=10), which
    survive shells that strip quotes (Windows PowerShell)."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        out = {}
        for part in filter(None, (p.strip() for p in text.strip("{}").split(","))):
            k, sep, v = part.partition("=") if "=" in part else part.partition(":")
            if not sep:
                raise ValueError(f"bad --params part {part!r}: use key=value")
            v = v.strip().strip('"\'')
            out[k.strip().strip('"\'')] = int(v) if v.lstrip("-").isdigit() else v
        return out


def table(data):
    if isinstance(data, str):
        return data
    if isinstance(data, dict) and "columns" in data and "rows" in data:
        data = [dict(zip(data["columns"], r)) for r in data["rows"]]
    if isinstance(data, dict):
        return json.dumps(data, ensure_ascii=False, indent=2, default=str)
    if not data:
        return "(no rows)"
    cols = list(data[0].keys())
    fmt = lambda v: f"{v:,.2f}" if isinstance(v, float) else ("" if v is None else str(v))
    cells = [[fmt(r.get(c)) for c in cols] for r in data]
    w = [min(40, max(len(c), *(len(x[i]) for x in cells))) for i, c in enumerate(cols)]
    line = lambda xs: "  ".join(x[:w[i]].ljust(w[i]) for i, x in enumerate(xs))
    return "\n".join([line(cols), line(["-" * n for n in w])] + [line(x) for x in cells])


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__); return 0
    if argv[0] == "--db":
        db.set_db(argv[1]); argv = argv[2:]
    name = argv.pop(0)
    if name == "build-views":
        f = argv[argv.index("--file") + 1] if "--file" in argv else None
        print("views:", ", ".join(db.build_views(f))); return 0
    if name == "check-queries":
        res = saved.check(argv[argv.index("--domain") + 1] if "--domain" in argv else None)
        print(table(res))
        bad = [r for r in res if r["error"]]
        print(f"\n{len(res)} queries, {len(bad)} failed, slowest {max((r['secs'] for r in res), default=0)} s")
        return 1 if bad else 0
    if name == "list":
        for k, (_, desc, _) in metrics.TOOLS.items():
            print(f"{k:24} {desc}")
        return 0
    if name not in metrics.TOOLS:
        print(f"unknown tool {name!r}; try: py -m bi list", file=sys.stderr); return 2
    fn, desc, schema = metrics.TOOLS[name]
    ap = argparse.ArgumentParser(prog=f"py -m bi {name}", description=desc)
    for p, s in schema.items():
        t = {"integer": int, "number": float, "object": parse_params}.get(s.get("type"), str)
        if s.get("type") == "boolean":
            ap.add_argument(f"--{p}", action="store_true")
        else:
            ap.add_argument(f"--{p}", type=t, choices=s.get("enum"), required=p in metrics.REQUIRED.get(name, []))
    ap.add_argument("--json", action="store_true", help="print JSON")
    a = vars(ap.parse_args(argv))
    as_json = a.pop("json")
    saved.LAST_TRUNCATED = False
    try:
        out = fn(**saved.resolve({k: v for k, v in a.items() if v not in (None, False)}))
    except (ValueError, sqlite3.Error) as e:
        hint = "  (py -m bi describe --name <view> lists columns)" if isinstance(e, sqlite3.Error) else ""
        print(f"error: {e}{hint}", file=sys.stderr); return 2
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=2, default=str))
    elif name == "saved_queries" and isinstance(out, list):
        for q in out:       # full descriptions: agents choose queries from them
            print(f"{q['name']}  [{q['domain']}]  params: {q['params']}\n    {q['description']}\n")
        print(f"{len(out)} saved queries")
    else:
        print(table(out))
    truncated = saved.LAST_TRUNCATED or (isinstance(out, dict) and out.get("truncated"))
    if truncated:
        print(f"\nNOTE: more rows exist than shown (limit reached); rerun with a higher --limit for totals.",
              file=sys.stderr if as_json else sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

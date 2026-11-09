"""Command line: py -m bi <tool> [--param value ...] [--json]

Examples:
  py -m bi build-views
  py -m bi kpis --start 2025-01-01 --end 2025-12-31
  py -m bi top_products --by margin --limit 10
  py -m bi customer_profile --query "<part of a name>"
  py -m bi query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
  py -m bi list
"""
import argparse
import json
import sys

from . import db, metrics


def table(data):
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
    name = argv.pop(0)
    if name == "build-views":
        print("views:", ", ".join(db.build_views())); return 0
    if name == "list":
        for k, (_, desc, _) in metrics.TOOLS.items():
            print(f"{k:24} {desc}")
        return 0
    if name not in metrics.TOOLS:
        print(f"unknown tool {name!r}; try: py -m bi list", file=sys.stderr); return 2
    fn, desc, schema = metrics.TOOLS[name]
    ap = argparse.ArgumentParser(prog=f"py -m bi {name}", description=desc)
    for p, s in schema.items():
        t = {"integer": int, "number": float, "object": json.loads}.get(s.get("type"), str)
        if s.get("type") == "boolean":
            ap.add_argument(f"--{p}", action="store_true")
        else:
            ap.add_argument(f"--{p}", type=t, choices=s.get("enum"), required=p in metrics.REQUIRED.get(name, []))
    ap.add_argument("--json", action="store_true", help="print JSON")
    a = vars(ap.parse_args(argv))
    as_json = a.pop("json")
    try:
        out = fn(**{k: v for k, v in a.items() if v not in (None, False)})
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr); return 2
    print(json.dumps(out, ensure_ascii=False, indent=2, default=str) if as_json else table(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())

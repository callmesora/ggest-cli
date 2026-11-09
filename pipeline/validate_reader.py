"""Validate the native .fic reader against WDMap's XML export of the same data.

For every table with rows: native rows vs XML rows, compared as multisets (row order differs),
plus per-column value-multiset mismatches with examples. Writes layouts/validation.tsv and prints
a summary. refresh.py --reader native only uses tables whose status here is "exact".

    py validate_reader.py --data C:\\...\\BDW --xml C:\\...\\export\\xml [--tables a,b]
"""
import argparse
import collections
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fic_reader import DEFAULT_LAYOUTS, check_fingerprint, load_layouts, read_table  # noqa: E402
from xmlrows import rows_of  # noqa: E402

DEFAULT_OUT = os.path.join(HERE, "layouts", "validation.tsv")


def statuses(xml_dir):
    st = {}
    for lp in sorted(os.listdir(xml_dir)):
        if lp.startswith("_log_worker") and lp.endswith(".tsv"):
            for line in open(os.path.join(xml_dir, lp), encoding="utf-8", errors="replace"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    name = parts[0].lstrip("\ufeff")
                    if st.get(name) != "OK":
                        st[name] = parts[2]
    return st


def validate_table(name, fic, xml, lay):
    t0 = time.time()
    xrows = list(rows_of(xml, name))
    cols = []
    for r in xrows:
        for c, _ in r:
            if c not in cols:
                cols.append(c)
    res = {"table": name, "xml_rows": len(xrows), "native_rows": 0, "rows_matched": 0,
           "status": "failed", "detail": ""}
    if not lay or not lay.get("columns") or lay.get("error"):
        res["detail"] = (lay or {}).get("error") or "no layout"
        return res
    ok, why, _ = check_fingerprint(fic, lay)
    if not ok:
        res["detail"] = "fingerprint: " + why
        return res
    try:
        nrows = list(read_table(fic, lay))
    except Exception as e:
        res["detail"] = f"read error {type(e).__name__}: {e}"
        return res
    res["native_rows"] = len(nrows)
    # rows as tuples over the XML column list (a column missing from a row = None)
    xt = collections.Counter(tuple(dict(r).get(c) for c in cols) for r in xrows)
    nt = collections.Counter(tuple(dict(r).get(c) for c in cols) for r in nrows)
    res["rows_matched"] = sum((xt & nt).values())
    bad_cols = []
    for j, c in enumerate(cols if xt != nt else []):
        xc = collections.Counter(k[j] for k in xt.elements())
        nc = collections.Counter(k[j] for k in nt.elements())
        if xc != nc:
            only_x = list((xc - nc).elements())[:2]
            only_n = list((nc - xc).elements())[:2]
            bad_cols.append(f"{c}[{sum((xc - nc).values())}] xml={only_x!r:.80} native={only_n!r:.80}")
    missing = [c for c in cols if c not in {x['name'] for x in lay["columns"]}]
    if res["rows_matched"] == len(xrows) == len(nrows):
        res["status"] = "exact"
    elif res["rows_matched"] > 0:
        res["status"] = "partial"
    res["bad_columns"] = len(bad_cols)
    res["detail"] = ("missing columns: " + ",".join(missing) + "; " if missing else "") + " | ".join(bad_cols[:6])
    res["seconds"] = round(time.time() - t0, 1)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True)
    ap.add_argument("--xml", required=True)
    ap.add_argument("--layouts", default=DEFAULT_LAYOUTS)
    ap.add_argument("--tables", default="")
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args()
    layouts = load_layouts(a.layouts)["tables"]
    st = statuses(a.xml)
    fics = {os.path.splitext(f)[0]: os.path.join(a.data, f) for f in os.listdir(a.data)
            if f.lower().endswith(".fic")}
    xmls = {os.path.splitext(f)[0].lower(): os.path.join(a.xml, f) for f in os.listdir(a.xml)
            if f.lower().endswith(".xml")}
    want = [t for t in a.tables.split(",") if t] or sorted(fics, key=str.lower)
    results = []
    t0 = time.time()
    for name in want:
        xml = xmls.get(name.lower())
        if not xml or st.get(name, "OK") != "OK" or name not in fics:
            continue
        r = validate_table(name, fics[name], xml, layouts.get(name))
        if r["xml_rows"] == 0:
            continue
        results.append(r)
        print(f"{r['status']:8s} {name:40s} {r['rows_matched']}/{r['xml_rows']} {r['detail'][:160]}", flush=True)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("table\tstatus\txml_rows\tnative_rows\trows_matched\tbad_columns\tdetail\n")
        for r in results:
            f.write(f"{r['table']}\t{r['status']}\t{r['xml_rows']}\t{r['native_rows']}\t{r['rows_matched']}\t"
                    f"{r.get('bad_columns', '')}\t{r['detail'].replace(chr(9), ' ').replace(chr(10), ' ')}\n")
    by = collections.Counter(r["status"] for r in results)
    tot = sum(r["xml_rows"] for r in results)
    ok_rows = sum(r["rows_matched"] for r in results)
    exact_rows = sum(r["xml_rows"] for r in results if r["status"] == "exact")
    print(f"\n{len(results)} tables with rows: {by.get('exact', 0)} exact, {by.get('partial', 0)} partial, "
          f"{by.get('failed', 0)} failed")
    print(f"rows matched exactly: {ok_rows:,} of {tot:,}; rows in 100%-exact tables: {exact_rows:,}")
    print(f"validation written to {a.out} ({time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()

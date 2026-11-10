r"""Validate the native .fic reader against WDMap's XML export of the same data.

For every table with rows: native rows vs XML rows, compared as multisets (row order differs),
plus per-column value-multiset mismatches with examples. Writes layouts/validation.tsv and prints
a summary. refresh.py --reader native only uses tables whose status here is "exact".

    py validate_reader.py --data C:\\...\\BDW --xml C:\\...\\export\\xml [--tables a,b]
"""

import argparse
import collections
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fic_reader import DEFAULT_LAYOUTS, check_fingerprint, fic_files, load_layouts, read_table  # noqa: E402
from xmlrows import export_statuses, first_seen_columns, rows_of, xml_files  # noqa: E402

DEFAULT_OUT = HERE / "layouts" / "validation.tsv"
TSV_HEADER = "table\tstatus\txml_rows\tnative_rows\trows_matched\tbad_columns\tdetail\n"
MAX_BAD_SHOWN = 6

Result = dict[str, Any]
RowKey = tuple[str | None, ...]


def _layout_problem(fic: str | Path, lay: dict[str, Any] | None) -> str | None:
    """Why the table cannot be read natively, or None."""
    if not lay or not lay.get("columns") or lay.get("error"):
        return (lay or {}).get("error") or "no layout"
    ok, why, _ = check_fingerprint(fic, lay)
    return None if ok else "fingerprint: " + why


def bad_columns(cols: list[str], xt: collections.Counter, nt: collections.Counter) -> list[str]:
    """Per column whose value multiset differs: name[count] and examples from both sides."""
    bad = []
    for j, c in enumerate(cols):
        xc = collections.Counter(k[j] for k in xt.elements())
        nc = collections.Counter(k[j] for k in nt.elements())
        if xc != nc:
            only_x = list((xc - nc).elements())[:2]
            only_n = list((nc - xc).elements())[:2]
            bad.append(f"{c}[{sum((xc - nc).values())}] xml={only_x!r:.80} native={only_n!r:.80}")
    return bad


def compare_rows(res: Result, cols: list[str], xrows: list, nrows: list, lay: dict[str, Any]) -> None:
    """Fill res with rows_matched, status, bad_columns and detail."""
    # rows as tuples over the XML column list (a column missing from a row = None)
    xt = collections.Counter(tuple(dict(r).get(c) for c in cols) for r in xrows)
    nt = collections.Counter(tuple(dict(r).get(c) for c in cols) for r in nrows)
    matched = sum((xt & nt).values())
    res["rows_matched"] = matched
    bad = bad_columns(cols, xt, nt) if xt != nt else []
    res["status"] = row_status(matched, len(xrows), len(nrows))
    res["bad_columns"] = len(bad)
    res["detail"] = detail(missing_columns(cols, lay), bad)


def row_status(matched: int, xml_rows: int, native_rows: int) -> str:
    """exact (every row matched on both sides), partial (some) or failed."""
    if matched == xml_rows == native_rows:
        return "exact"
    return "partial" if matched > 0 else "failed"


def missing_columns(cols: list[str], lay: dict[str, Any]) -> list[str]:
    """XML columns the layout does not read."""
    names = {x["name"] for x in lay["columns"]}
    return [c for c in cols if c not in names]


def detail(missing: list[str], bad: list[str]) -> str:
    """Detail text: missing columns, then the first mismatching columns."""
    head = "missing columns: " + ",".join(missing) + "; " if missing else ""
    return head + " | ".join(bad[:MAX_BAD_SHOWN])


def validate_table(name: str, fic: str | Path, xml: str | Path, lay: dict[str, Any] | None) -> Result:
    """Compare the native rows of one table with its XML export."""
    t0 = time.time()
    xrows = list(rows_of(xml, name))
    cols = first_seen_columns(xrows)
    res = {"table": name, "xml_rows": len(xrows), "native_rows": 0, "rows_matched": 0,
           "status": "failed", "detail": ""}  # fmt: skip
    problem = _layout_problem(fic, lay)
    if problem:
        res["detail"] = problem
        return res
    try:
        nrows = list(read_table(fic, lay))
    except Exception as e:  # noqa: BLE001 - any reader failure is a validation result, not a crash
        res["detail"] = f"read error {type(e).__name__}: {e}"
        return res
    res["native_rows"] = len(nrows)
    compare_rows(res, cols, xrows, nrows, lay)
    res["seconds"] = round(time.time() - t0, 1)
    return res


def tsv_line(r: Result) -> str:
    """One validation.tsv line (tabs and newlines in the detail become spaces)."""
    detail = r["detail"].replace("\t", " ").replace("\n", " ")
    return (f"{r['table']}\t{r['status']}\t{r['xml_rows']}\t{r['native_rows']}\t{r['rows_matched']}\t"
            f"{r.get('bad_columns', '')}\t{detail}\n")  # fmt: skip


def write_tsv(path: Path, results: list[Result]) -> None:
    """Write validation.tsv."""
    path.resolve().parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write(TSV_HEADER)
        f.writelines(tsv_line(r) for r in results)


def summary(results: list[Result]) -> list[str]:
    """Summary lines: tables per status and rows matched."""
    by = collections.Counter(r["status"] for r in results)
    tot = sum(r["xml_rows"] for r in results)
    ok_rows = sum(r["rows_matched"] for r in results)
    exact_rows = sum(r["xml_rows"] for r in results if r["status"] == "exact")
    return [
        (
            f"\n{len(results)} tables with rows: {by.get('exact', 0)} exact, {by.get('partial', 0)} partial, "
            f"{by.get('failed', 0)} failed"
        ),
        f"rows matched exactly: {ok_rows:,} of {tot:,}; rows in 100%-exact tables: {exact_rows:,}",
    ]


def validate_all(data: str, xml_dir: str, layouts: dict[str, Any], tables: list[str]) -> list[Result]:
    """Validate the wanted tables (all .fic tables by default) that have an OK XML export with rows."""
    st = export_statuses(xml_dir)
    fics, xmls = fic_files(data), xml_files(xml_dir)
    results = []
    for name in tables or sorted(fics, key=str.lower):
        xml = xmls.get(name.lower())
        if not xml or st.get(name, "OK") != "OK" or name not in fics:
            continue
        r = validate_table(name, fics[name], xml, layouts.get(name))
        if r["xml_rows"] == 0:
            continue
        results.append(r)
        print(f"{r['status']:8s} {name:40s} {r['rows_matched']}/{r['xml_rows']} {r['detail'][:160]}", flush=True)
    return results


def main(argv: list[str] | None = None) -> None:
    """CLI: validate, write the TSV and print a summary."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True)
    ap.add_argument("--xml", required=True)
    ap.add_argument("--layouts", default=str(DEFAULT_LAYOUTS))
    ap.add_argument("--tables", default="")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    a = ap.parse_args(argv)
    t0 = time.time()
    tables = [t for t in a.tables.split(",") if t]
    results = validate_all(a.data, a.xml, load_layouts(a.layouts)["tables"], tables)
    write_tsv(Path(a.out), results)
    for line in summary(results):
        print(line)
    print(f"validation written to {a.out} ({time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()

"""Refresh everything from a gGest data folder in one command.

    py pipeline/refresh.py --source "\\\\SERVIDOR\\gGest\\Dados"

Steps (nothing appears on screen, no clicking; you can keep using the PC):
  1. copy the data folder (.fic/.ndx/.mmo) to a work folder — the live files are only read, never opened by WDMap
  2. export every table to XML with WDMap on a hidden desktop (parallel workers, failed tables retried once)
  3. build data/data.sqlite (+ business views + memo files), swapped in only when complete
  4. regenerate the dashboard datasets (dashboards/datasets/*.json)

Options: --workers 4 (parallel WDMap copies), --tables a,b (only these tables — for tests),
         --out <folder> (build somewhere else instead of data/), --skip-dashboard, --keep-work,
         --reader native (read the .fic files directly with the learned layouts in
           pipeline/layouts/; tables without a validated layout, or whose layout fingerprint
           changed after a gGest update, still go through WDMap and are re-learned from that export).
         Default reader: wdmap.
Then ask Claude to upload the new dashboard datasets (the files in dashboards/datasets).
"""
import argparse
import datetime
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent


def log(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


def export(fic_dir, xml_dir, workers, tables):
    ps = str(HERE / "hidden_export.ps1")
    base = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps,
            "-DataDir", str(fic_dir), "-OutDir", str(xml_dir), "-Workers", str(workers)]
    if tables:
        base += ["-Tables", ",".join(tables)]
    procs = [subprocess.Popen(base + ["-Worker", str(w)]) for w in range(workers)]
    for p in procs:
        p.wait()


def statuses(xml_dir):
    st = {}
    for lp in sorted(Path(xml_dir).glob("_log_worker*.tsv")):
        for line in lp.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                name = parts[0].lstrip("﻿")
                if st.get(name) != "OK":
                    st[name] = parts[2]
    return st


def relearn(fic_dir, xml_dir, names):
    """Re-learn and validate layouts of tables that WDMap had to export (new/changed tables), so the
    next native refresh can read them; only layouts that reproduce WDMap's rows exactly are kept."""
    if not names:
        return
    log(f"    re-learning layouts of {len(names)} table(s) from this WDMap export")
    lay_dir = HERE / "layouts"
    tmp = lay_dir / "_relearn.json"
    tval = lay_dir / "_relearn_validation.tsv"
    r = subprocess.run([sys.executable, str(HERE / "fic_layout.py"), "--data", str(fic_dir), "--xml", str(xml_dir),
                        "--tables", ",".join(names), "--out", str(tmp)], stdout=subprocess.DEVNULL)
    if r.returncode or not tmp.exists():
        log("    re-learning failed; these tables stay on WDMap")
        return
    subprocess.run([sys.executable, str(HERE / "validate_reader.py"), "--data", str(fic_dir), "--xml", str(xml_dir),
                    "--layouts", str(tmp), "--tables", ",".join(names), "--out", str(tval)], stdout=subprocess.DEVNULL)
    import csv
    import json
    new = json.loads(tmp.read_text(encoding="utf-8"))["tables"]
    val = {}
    if tval.exists():
        with open(tval, encoding="utf-8") as f:
            val = {row["table"]: row for row in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)}
    main_json, main_val = lay_dir / "ggest_layouts.json", lay_dir / "validation.tsv"
    doc = json.loads(main_json.read_text(encoding="utf-8"))
    with open(main_val, encoding="utf-8") as f:
        vrows = {row["table"]: row for row in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)}
    kept = []
    for t, lay in new.items():
        if (val.get(t, {}).get("status") == "exact") or (not lay.get("columns") and lay.get("empty_sha1")):
            doc["tables"][t] = lay
            if t in val:
                vrows[t] = val[t]
            kept.append(t)
    if kept:
        shutil.copy2(main_json, str(main_json) + ".bak")
        main_json.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        cols = ["table", "status", "xml_rows", "native_rows", "rows_matched", "bad_columns", "detail"]
        with open(main_val, "w", encoding="utf-8", newline="") as f:
            f.write("\t".join(cols) + "\n")
            for row in vrows.values():
                f.write("\t".join(str(row.get(c, "")) for c in cols) + "\n")
    log(f"    re-learned {len(kept)} table(s): {', '.join(kept[:10])}{' ...' if len(kept) > 10 else ''}")
    tmp.unlink(missing_ok=True)
    tval.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, help="gGest data folder (with the .fic files)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--tables", default="", help="comma-separated table names (default: all)")
    ap.add_argument("--out", default=str(PROJECT / "data"), help="where data.sqlite and memo_files go")
    ap.add_argument("--work", default=str(PROJECT / "data" / "work"), help="folder for the copied files and XML")
    ap.add_argument("--skip-dashboard", action="store_true")
    ap.add_argument("--keep-work", action="store_true", help="keep the copied files and XML afterwards")
    ap.add_argument("--reader", choices=["wdmap", "native"], default="wdmap",
                    help="wdmap = export every table with WDMap (default); native = read .fic directly, "
                         "WDMap only for tables without a valid layout")
    ap.add_argument("--no-relearn", action="store_true",
                    help="native reader: do not re-learn layouts of tables that fell back to WDMap")
    a = ap.parse_args()

    src = Path(a.source)
    if not any(src.glob("*.fic")) and not any(src.glob("*.FIC")):
        sys.exit(f"no .fic files in {src}")
    tables = [t for t in a.tables.split(",") if t]
    work = Path(a.work) / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    fic_dir, xml_dir = work / "fic", work / "xml"
    t0 = time.time()

    log(f"1/4 copying {src} -> {fic_dir}")
    fic_dir.mkdir(parents=True)
    for f in src.iterdir():
        if f.is_file() and f.suffix.lower() in (".fic", ".ndx", ".mmo", ".ftx") and (not tables or f.stem in tables):
            shutil.copy2(f, fic_dir / f.name)

    wdmap_tables = tables
    fallback = {}
    if a.reader == "native":
        log("2/4 reading tables with the native reader")
        import native_export
        done, fallback = native_export.export(str(fic_dir), str(xml_dir), tables, log=log)
        for t, why in sorted(fallback.items()):
            log(f"    WDMap fallback: {t} ({why})")
        wdmap_tables = sorted(fallback)
    if a.reader == "wdmap" or wdmap_tables:
        log(f"2/4 exporting {len(wdmap_tables) if wdmap_tables else 'all'} table(s) with WDMap (hidden, {a.workers} workers)")
        export(fic_dir, xml_dir, a.workers, wdmap_tables)
    failed = [n for n, s in statuses(xml_dir).items() if s not in ("OK", "EMPTY_OR_NO_EXPORT")]
    if failed:
        log(f"    retrying {len(failed)} table(s): {', '.join(failed[:10])}")
        export(fic_dir, xml_dir, 1, failed)
    st = statuses(xml_dir)
    ok = sum(1 for s in st.values() if s == "OK")
    empty = sum(1 for s in st.values() if s == "EMPTY_OR_NO_EXPORT")
    still = [n for n, s in st.items() if s not in ("OK", "EMPTY_OR_NO_EXPORT")]
    log(f"    {ok} tables exported, {empty} empty, {len(still)} failed {still[:10] if still else ''}")

    if fallback and not a.no_relearn:
        relearn(fic_dir, xml_dir, [t for t in fallback if st.get(t) in ("OK", "EMPTY_OR_NO_EXPORT")])

    log(f"3/4 building {Path(a.out) / 'data.sqlite'}")
    args = [sys.executable, str(HERE / "build_sqlite.py"), str(xml_dir), str(fic_dir), a.out]
    if tables:
        args.append("--only-exported")
    with open(work / "build_log.tsv", "w", encoding="utf-8") as fh:
        subprocess.run(args, check=True, stdout=fh, stderr=subprocess.STDOUT)

    if not a.skip_dashboard and Path(a.out).resolve() == (PROJECT / "data").resolve():
        log("4/4 regenerating dashboard datasets")
        subprocess.run([sys.executable, str(PROJECT / "dashboards" / "export_datasets.py")], check=True,
                       stdout=subprocess.DEVNULL)
    else:
        log("4/4 dashboard datasets skipped")

    if not a.keep_work:
        shutil.rmtree(fic_dir, ignore_errors=True)
    log(f"done in {int(time.time() - t0) // 60} min. Export log and XML: {xml_dir}")
    if still:
        log("some tables failed: run the same command again, or check the screenshots in the log folder")


if __name__ == "__main__":
    main()

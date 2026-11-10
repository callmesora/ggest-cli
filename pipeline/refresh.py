r"""Refresh everything from a gGest data folder in one command.

    uv run python pipeline/refresh.py --source "\\\\SERVIDOR\\gGest\\Dados"

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
import csv
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
sys.path.insert(0, str(HERE))
import native_export  # noqa: E402
from xmlrows import export_statuses  # noqa: E402

LAYOUTS = HERE / "layouts"
SOURCE_SUFFIXES = (".fic", ".ndx", ".mmo", ".ftx")
DONE = ("OK", "EMPTY_OR_NO_EXPORT")
SHOWN = 10  # table names listed in progress lines
VALIDATION_COLUMNS = ["table", "status", "xml_rows", "native_rows", "rows_matched", "bad_columns", "detail"]


def log(msg: str) -> None:
    """Print a timestamped progress line."""
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def export(fic_dir: Path, xml_dir: Path, workers: int, tables: list[str]) -> None:
    """Export tables (all when empty) with WDMap on a hidden desktop, in parallel workers."""
    ps = str(HERE / "hidden_export.ps1")
    base = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps,
            "-DataDir", str(fic_dir), "-OutDir", str(xml_dir), "-Workers", str(workers)]  # fmt: skip
    if tables:
        base += ["-Tables", ",".join(tables)]
    procs = [subprocess.Popen([*base, "-Worker", str(w)]) for w in range(workers)]
    for p in procs:
        p.wait()


def read_tsv(path: Path) -> dict[str, dict[str, str]]:
    """{table: row} of a validation TSV."""
    with path.open(encoding="utf-8") as f:
        return {row["table"]: row for row in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)}


def write_validation(path: Path, rows: dict[str, dict[str, str]]) -> None:
    """Write validation.tsv (LF line ends)."""
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write("\t".join(VALIDATION_COLUMNS) + "\n")
        for row in rows.values():
            f.write("\t".join(str(row.get(c, "")) for c in VALIDATION_COLUMNS) + "\n")


def merge_relearned(new: dict, val: dict, doc: dict, vrows: dict) -> list[str]:
    """Copy into doc/vrows the new layouts that validated exactly (or are unchanged empty tables)."""
    kept = []
    for t, lay in new.items():
        if (val.get(t, {}).get("status") == "exact") or (not lay.get("columns") and lay.get("empty_sha1")):
            doc["tables"][t] = lay
            if t in val:
                vrows[t] = val[t]
            kept.append(t)
    return kept


def _learn_and_validate(fic_dir: Path, xml_dir: Path, names: list[str], tmp: Path, tval: Path) -> bool:
    """Run fic_layout.py and validate_reader.py on these tables into tmp/tval; False if learning failed."""
    common = ["--data", str(fic_dir), "--xml", str(xml_dir)]
    tables = ["--tables", ",".join(names)]
    r = subprocess.run([sys.executable, str(HERE / "fic_layout.py"), *common, *tables, "--out", str(tmp)],
                       stdout=subprocess.DEVNULL, check=False)  # fmt: skip
    if r.returncode or not tmp.exists():
        return False
    subprocess.run([sys.executable, str(HERE / "validate_reader.py"), *common, "--layouts", str(tmp), *tables,
                    "--out", str(tval)], stdout=subprocess.DEVNULL, check=False)  # fmt: skip
    return True


def relearn(fic_dir: Path, xml_dir: Path, names: list[str], lay_dir: Path = LAYOUTS) -> None:
    """Re-learn and validate layouts of tables that WDMap had to export (new/changed tables), so the
    next native refresh can read them; only layouts that reproduce WDMap's rows exactly are kept."""
    if not names:
        return
    log(f"    re-learning layouts of {len(names)} table(s) from this WDMap export")
    tmp, tval = lay_dir / "_relearn.json", lay_dir / "_relearn_validation.tsv"
    if not _learn_and_validate(fic_dir, xml_dir, names, tmp, tval):
        log("    re-learning failed; these tables stay on WDMap")
        return
    new = json.loads(tmp.read_text(encoding="utf-8"))["tables"]
    val = read_tsv(tval) if tval.exists() else {}
    main_json, main_val = lay_dir / "ggest_layouts.json", lay_dir / "validation.tsv"
    doc = json.loads(main_json.read_text(encoding="utf-8"))
    vrows = read_tsv(main_val)
    kept = merge_relearned(new, val, doc, vrows)
    if kept:
        shutil.copy2(main_json, str(main_json) + ".bak")
        main_json.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        write_validation(main_val, vrows)
    if kept:
        log(f"    re-learned {len(kept)} table(s): {', '.join(kept[:SHOWN])}{' ...' if len(kept) > SHOWN else ''}")
    else:
        log("    no new layout reproduced WDMap exactly; these tables keep using WDMap (normal for a few tables)")
    tmp.unlink(missing_ok=True)
    tval.unlink(missing_ok=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Command-line options."""
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
                         "WDMap only for tables without a valid layout")  # fmt: skip
    ap.add_argument("--no-relearn", action="store_true",
                    help="native reader: do not re-learn layouts of tables that fell back to WDMap")  # fmt: skip
    return ap.parse_args(argv)


def copy_sources(src: Path, fic_dir: Path, tables: list[str]) -> None:
    """Copy the data files (only those of the given tables, if any) to the work folder."""
    fic_dir.mkdir(parents=True)
    for f in src.iterdir():
        if f.is_file() and f.suffix.lower() in SOURCE_SUFFIXES and (not tables or f.stem in tables):
            shutil.copy2(f, fic_dir / f.name)


def read_native(fic_dir: Path, xml_dir: Path, tables: list[str]) -> dict[str, str]:
    """Native export; returns {table: reason} of the tables left for WDMap."""
    log("2/4 reading tables with the native reader")
    _, fallback = native_export.export(str(fic_dir), str(xml_dir), tables, log=log)
    for t, why in sorted(fallback.items()):
        log(f"    WDMap fallback: {t} ({why})")
    return fallback


def export_with_wdmap(fic_dir: Path, xml_dir: Path, workers: int, tables: list[str]) -> None:
    """WDMap export of these tables (all when empty)."""
    log(f"2/4 exporting {len(tables) if tables else 'all'} table(s) with WDMap (hidden, {workers} workers)")
    export(fic_dir, xml_dir, workers, tables)


def retry_failed(fic_dir: Path, xml_dir: Path) -> dict[str, str]:
    """Retry tables whose export failed; returns the statuses and logs a summary."""
    failed = [n for n, s in export_statuses(xml_dir).items() if s not in DONE]
    if failed:
        log(f"    retrying {len(failed)} table(s): {', '.join(failed[:SHOWN])}")
        export(fic_dir, xml_dir, 1, failed)
    st = export_statuses(xml_dir)
    log("    " + export_summary(st))
    return st


def export_summary(st: dict[str, str]) -> str:
    """Tables exported, empty and failed (with the first failed names)."""
    ok = sum(1 for s in st.values() if s == "OK")
    empty = sum(1 for s in st.values() if s == "EMPTY_OR_NO_EXPORT")
    still = [n for n, s in st.items() if s not in DONE]
    return f"{ok} tables exported, {empty} empty, {len(still)} failed {still[:SHOWN] if still else ''}"


def build(xml_dir: Path, fic_dir: Path, out: str, only_exported: bool, log_path: Path) -> None:
    """Run build_sqlite.py, its output going to log_path."""
    log(f"3/4 building {Path(out) / 'data.sqlite'}")
    args = [sys.executable, str(HERE / "build_sqlite.py"), str(xml_dir), str(fic_dir), out]
    if only_exported:
        args.append("--only-exported")
    with log_path.open("w", encoding="utf-8") as fh:
        subprocess.run(args, check=True, stdout=fh, stderr=subprocess.STDOUT)


def dashboards(out: str, skip: bool) -> None:
    """Regenerate the dashboard datasets when the live database was rebuilt."""
    if not skip and Path(out).resolve() == (PROJECT / "data").resolve():
        log("4/4 regenerating dashboard datasets")
        subprocess.run([sys.executable, str(PROJECT / "dashboards" / "export_datasets.py")], check=True,
                       stdout=subprocess.DEVNULL)  # fmt: skip
    else:
        log("4/4 dashboard datasets skipped")


def export_all(a: argparse.Namespace, fic_dir: Path, xml_dir: Path, tables: list[str]) -> dict[str, str]:
    """Native and/or WDMap export, retry, re-learn of the fallbacks; returns the export statuses."""
    wdmap_tables, fallback = tables, {}
    if a.reader == "native":
        fallback = read_native(fic_dir, xml_dir, tables)
        wdmap_tables = sorted(fallback)
    if a.reader == "wdmap" or wdmap_tables:
        export_with_wdmap(fic_dir, xml_dir, a.workers, wdmap_tables)
    st = retry_failed(fic_dir, xml_dir)
    if fallback and not a.no_relearn:
        relearn(fic_dir, xml_dir, [t for t in fallback if st.get(t) in DONE])
    return st


def main(argv: list[str] | None = None) -> None:
    """CLI: copy, export (native and/or WDMap), re-learn, build, dashboards."""
    a = parse_args(argv)
    src = Path(a.source)
    if not any(src.glob("*.fic")) and not any(src.glob("*.FIC")):
        sys.exit(f"no .fic files in {src}")
    tables = [t for t in a.tables.split(",") if t]
    work = Path(a.work) / time.strftime("%Y%m%d-%H%M%S")
    fic_dir, xml_dir = work / "fic", work / "xml"
    t0 = time.time()

    log(f"1/4 copying {src} -> {fic_dir}")
    copy_sources(src, fic_dir, tables)
    st = export_all(a, fic_dir, xml_dir, tables)
    build(xml_dir, fic_dir, a.out, bool(tables), work / "build_log.tsv")
    dashboards(a.out, a.skip_dashboard)
    if not a.keep_work:
        shutil.rmtree(fic_dir, ignore_errors=True)
    log(f"done in {int(time.time() - t0) // 60} min. Export log and XML: {xml_dir}")
    if any(s not in DONE for s in st.values()):
        log("some tables failed: run the same command again, or check the screenshots in the log folder")


if __name__ == "__main__":
    main()

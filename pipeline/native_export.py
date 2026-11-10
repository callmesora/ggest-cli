"""Native export: read gGest .fic files with the learned layouts and write per-table XML files
in WDMap's export format, so build_sqlite.py builds from them unchanged.

A table is read natively only when
  - it has a learned layout (layouts/ggest_layouts.json) without errors,
  - it passed validation against WDMap (layouts/validation.tsv status "exact"), and
  - its fingerprint still matches (record size and position of record 0, which change when gGest
    changes the table definition).
Tables that were empty when the layouts were learned are exported as empty only while their .fic
is byte-identical to the learned one. Everything else is returned as a fallback list for WDMap.

    py native_export.py <fic_dir> <xml_dir> [--tables a,b]
"""

import argparse
import csv
import hashlib
import json
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fic_reader import DEFAULT_LAYOUTS, check_fingerprint, fic_files, load_layouts, read_table, write_xml  # noqa: E402

DEFAULT_VALIDATION = HERE / "layouts" / "validation.tsv"
LOG_NAME = "_log_worker_native.tsv"  # matches the _log_worker*.tsv glob used by refresh/build
EMPTY = "EMPTY_OR_NO_EXPORT"

# (log line, None) when the table was read natively; (None, reason) for a WDMap fallback
Outcome = tuple[str | None, str | None]


def load_validation(path: str | Path = DEFAULT_VALIDATION) -> dict[str, str]:
    """{table: status} from validation.tsv ({} if it does not exist)."""
    path = Path(path)
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        return {r["table"]: r["status"] for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)}


def sha1(path: str | Path) -> str:
    """SHA-1 of a file (identity check, not security)."""
    h = hashlib.sha1(usedforsecurity=False)
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _empty_table(name: str, fic: Path, lay: dict[str, Any]) -> Outcome:
    """A table learned without rows is exported as empty while its .fic is unchanged."""
    if lay.get("empty_sha1") and lay["empty_sha1"] == sha1(fic):
        return f"{name}\t{fic.stat().st_size}\t{EMPTY}\t0\t0\n", None
    return None, lay.get("error") or "table had no rows when learned and has changed"


def export_table(name: str, fic: Path, lay: dict[str, Any] | None, status: str, xml_dir: Path) -> Outcome:
    """Write one table's XML if it can be read natively."""
    t0 = time.time()
    if lay is None:
        return None, "no layout (new table?)"
    if not lay.get("columns"):
        return _empty_table(name, fic, lay)
    if status != "exact":
        return None, f"validation status {status}"
    ok, why, _ = check_fingerprint(fic, lay)
    if not ok:
        return None, "fingerprint changed: " + why
    out = xml_dir / f"{name}.XML"
    try:
        n = write_xml(out, name, read_table(fic, lay))
    except Exception as e:  # noqa: BLE001 - any reader failure sends the table to WDMap
        return None, f"read error {type(e).__name__}: {e}"
    if not n:
        out.unlink()
    return f"{name}\t{fic.stat().st_size}\t{'OK' if n else EMPTY}\t{n}\t{time.time() - t0:.1f}\n", None


def export(
    fic_dir: str | Path,
    xml_dir: str | Path,
    tables: list[str] | None = None,
    layouts_path: str | Path = DEFAULT_LAYOUTS,
    validation_path: str | Path = DEFAULT_VALIDATION,
    log: Callable[[str], object] = print,
) -> tuple[list[str], dict[str, str]]:
    """Returns (native_tables, fallback {table: reason})."""
    xml_dir = Path(xml_dir)
    xml_dir.mkdir(parents=True, exist_ok=True)
    layouts = load_layouts(layouts_path)["tables"]
    valid = load_validation(validation_path)
    fics = fic_files(fic_dir)
    names = sorted((t for t in fics if not tables or t in tables), key=str.lower)
    done, fallback = [], {}
    t_all = time.time()
    with (xml_dir / LOG_NAME).open("a", encoding="utf-8") as logf:
        for name in names:
            line, reason = export_table(name, fics[name], layouts.get(name), valid.get(name, "missing"), xml_dir)
            if line is None:
                fallback[name] = reason
            else:
                logf.write(line)
                done.append(name)
    log(f"    native reader: {len(done)} tables in {time.time() - t_all:.0f}s, {len(fallback)} for WDMap")
    return done, fallback


def main(argv: list[str] | None = None) -> None:
    """CLI: export, print the fallbacks and write _native_export.json."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fic_dir")
    ap.add_argument("xml_dir")
    ap.add_argument("--tables", default="")
    ap.add_argument("--layouts", default=str(DEFAULT_LAYOUTS))
    ap.add_argument("--validation", default=str(DEFAULT_VALIDATION))
    a = ap.parse_args(argv)
    tables = [t for t in a.tables.split(",") if t]
    done, fb = export(a.fic_dir, a.xml_dir, tables, a.layouts, a.validation)
    for t, why in sorted(fb.items()):
        print(f"fallback {t}: {why}")
    (Path(a.xml_dir) / "_native_export.json").write_text(json.dumps({"native": done, "fallback": fb}, indent=1))


if __name__ == "__main__":
    main()

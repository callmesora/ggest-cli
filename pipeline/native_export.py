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
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fic_reader import DEFAULT_LAYOUTS, check_fingerprint, load_layouts, read_table, write_xml  # noqa: E402

DEFAULT_VALIDATION = os.path.join(HERE, "layouts", "validation.tsv")
LOG_NAME = "_log_worker_native.tsv"   # matches the _log_worker*.tsv glob used by refresh/build


def load_validation(path=DEFAULT_VALIDATION):
    st = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                st[r["table"]] = r["status"]
    return st


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def export(fic_dir, xml_dir, tables=None, layouts_path=DEFAULT_LAYOUTS, validation_path=DEFAULT_VALIDATION,
           log=print):
    """Returns (native_tables, fallback {table: reason})."""
    os.makedirs(xml_dir, exist_ok=True)
    layouts = load_layouts(layouts_path)["tables"]
    valid = load_validation(validation_path)
    fics = {os.path.splitext(f)[0]: os.path.join(fic_dir, f) for f in os.listdir(fic_dir)
            if f.lower().endswith(".fic")}
    names = sorted((t for t in fics if not tables or t in tables), key=str.lower)
    done, fallback = [], {}
    logf = open(os.path.join(xml_dir, LOG_NAME), "a", encoding="utf-8")
    t_all = time.time()
    for name in names:
        fic = fics[name]
        lay = layouts.get(name)
        t0 = time.time()
        if lay is None:
            fallback[name] = "no layout (new table?)"
            continue
        if not lay.get("columns"):
            if lay.get("empty_sha1") and lay["empty_sha1"] == sha1(fic):
                logf.write(f"{name}\t{os.path.getsize(fic)}\tEMPTY_OR_NO_EXPORT\t0\t0\n")
                done.append(name)
            else:
                fallback[name] = lay.get("error") or "table had no rows when learned and has changed"
            continue
        if valid.get(name) != "exact":
            fallback[name] = f"validation status {valid.get(name, 'missing')}"
            continue
        ok, why, _ = check_fingerprint(fic, lay)
        if not ok:
            fallback[name] = "fingerprint changed: " + why
            continue
        try:
            n = write_xml(os.path.join(xml_dir, name + ".XML"), name, read_table(fic, lay))
        except Exception as e:
            fallback[name] = f"read error {type(e).__name__}: {e}"
            continue
        status = "OK" if n else "EMPTY_OR_NO_EXPORT"
        if not n:
            os.remove(os.path.join(xml_dir, name + ".XML"))
        logf.write(f"{name}\t{os.path.getsize(fic)}\t{status}\t{n}\t{time.time() - t0:.1f}\n")
        done.append(name)
    logf.close()
    log(f"    native reader: {len(done)} tables in {time.time() - t_all:.0f}s, {len(fallback)} for WDMap")
    return done, fallback


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fic_dir")
    ap.add_argument("xml_dir")
    ap.add_argument("--tables", default="")
    ap.add_argument("--layouts", default=DEFAULT_LAYOUTS)
    ap.add_argument("--validation", default=DEFAULT_VALIDATION)
    a = ap.parse_args()
    tables = [t for t in a.tables.split(",") if t]
    done, fb = export(a.fic_dir, a.xml_dir, tables, a.layouts, a.validation)
    for t, why in sorted(fb.items()):
        print(f"fallback {t}: {why}")
    json.dump({"native": done, "fallback": fb}, open(os.path.join(a.xml_dir, "_native_export.json"), "w"), indent=1)


if __name__ == "__main__":
    main()

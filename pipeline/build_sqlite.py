"""Build one SQLite database from WDMap XML exports + memo files.

- Every table becomes a SQLite table; every value is stored as TEXT exactly as exported
  (dates stay as WinDev strings like 20200630134209799; profile before converting).
- Column `_row` = 1-based position of the row in the export (WDMap exports in record order).
- Binary memos (.mmo, images/attachments) are written to files and listed in table `_memo_files`
  (table, record number, item index, type, original file name, path, size).
- Table `_tables` holds per-table row counts and status from the export log.

Usage: py build_sqlite.py <xml_dir> <data_dir with .fic/.mmo> <out_dir> [--no-memos] [--only-exported]
"""
import glob, html, os, re, sqlite3, sys, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hfsql_mmo import Mmo, first_blocks, parse

import argparse
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("xml_dir"); ap.add_argument("data_dir"); ap.add_argument("out_dir")
ap.add_argument("--no-memos", action="store_true", help="skip .mmo extraction (fast build)")
ap.add_argument("--only-exported", action="store_true", help="only tables that have an XML export")
args = ap.parse_args()
xml_dir, data_dir, out_dir = args.xml_dir, args.data_dir, args.out_dir
os.makedirs(out_dir, exist_ok=True)
final_path = os.path.join(out_dir, "data.sqlite")
db_path = final_path + ".building"   # swapped in at the end, so readers never see a half-built file
if os.path.exists(db_path):
    os.remove(db_path)
db = sqlite3.connect(db_path)
db.execute("CREATE TABLE _tables(name TEXT PRIMARY KEY, rows INTEGER, columns INTEGER, export_status TEXT, fic_bytes INTEGER)")
db.execute("CREATE TABLE _memo_files(tbl TEXT, rec INTEGER, item INTEGER, kind TEXT, ext TEXT, original_name TEXT, path TEXT, bytes INTEGER, sha1 TEXT)")
db.execute("CREATE TABLE _memo_texts(tbl TEXT, rec INTEGER, item INTEGER, text TEXT)")

# export log (status per table)
status = {}
for lp in glob.glob(os.path.join(xml_dir, "_log_worker*.tsv")):
    for line in open(lp, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            name = parts[0].lstrip("﻿")
            # a retry may log the same table again: a success wins over an earlier failure
            if status.get(name) != "OK":
                status[name] = parts[2]

from xmlrows import rows_of


def q(n):
    return '"' + n.replace('"', '""') + '"'


fics = {os.path.splitext(os.path.basename(p))[0]: p for p in glob.glob(os.path.join(data_dir, "*.fic")) + glob.glob(os.path.join(data_dir, "*.FIC"))}
for name in sorted(fics, key=str.lower):
    xml = os.path.join(xml_dir, name + ".XML")
    if args.only_exported and not os.path.exists(xml):
        continue
    cols, n = [], 0
    if os.path.exists(xml):
        # columns are added as they are first seen
        db.execute(f"CREATE TABLE {q(name)} (_row INTEGER PRIMARY KEY)")
        rows = []
        for row in rows_of(xml, name):
            for c, _ in row:
                if c not in cols:
                    cols.append(c)
                    db.execute(f"ALTER TABLE {q(name)} ADD COLUMN {q(c)} TEXT")
            n += 1
            d = dict(row)
            rows.append([n] + [d.get(c) for c in cols])
            if len(rows) >= 5000:
                db.executemany(f"INSERT INTO {q(name)} (_row, {', '.join(map(q, cols))}) VALUES ({', '.join('?' * (len(cols) + 1))})",
                               [r + [None] * (len(cols) + 1 - len(r)) for r in rows])
                rows = []
        if rows:
            db.executemany(f"INSERT INTO {q(name)} (_row, {', '.join(map(q, cols))}) VALUES ({', '.join('?' * (len(cols) + 1))})",
                           [r + [None] * (len(cols) + 1 - len(r)) for r in rows])
    db.execute("INSERT INTO _tables VALUES (?,?,?,?,?)", (name, n, len(cols), status.get(name, "not exported"), os.path.getsize(fics[name])))

    # memos
    mmo = os.path.splitext(fics[name])[0] + ".mmo"
    if not args.no_memos and os.path.exists(mmo) and os.path.getsize(mmo) > 0xD2:
        m = Mmo(mmo)
        try:
            heads = first_blocks(m)
        except ValueError as e:
            print(name, "memo walk error", e)
            heads = []
        for h in heads:
            try:
                r = parse(m.raw(h))
            except Exception as e:
                print(name, "memo error", hex(h), e)
                continue
            if r["kind"] == "text":
                db.execute("INSERT INTO _memo_texts VALUES (?,?,?,?)", (name, r.get("rec"), r.get("item"), r["text"]))
            elif r["kind"] == "binary" and r["data"]:
                orig = r["names"][0] or r["names"][1]
                rec = r.get("rec")
                sub = os.path.join(out_dir, "memo_files", name)
                os.makedirs(sub, exist_ok=True)
                fn = f"rec{rec if rec is not None else 'NA'}_item{r['item']}_off{h:x}.{r['ext']}"
                p = os.path.join(sub, fn)
                with open(p, "wb") as f:
                    f.write(r["data"])
                db.execute("INSERT INTO _memo_files VALUES (?,?,?,?,?,?,?,?,?)",
                           (name, rec, r["item"], r["kind"], r["ext"], orig, os.path.relpath(p, out_dir), len(r["data"]),
                            hashlib.sha1(r["data"]).hexdigest()))
    db.commit()
    print(f"{name}\t{n}\t{len(cols)}", flush=True)
# business views (bi/sql/semantic.sql) so the database is ready to query
sem = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bi", "sql", "semantic.sql")
if os.path.exists(sem):
    try:
        db.executescript(open(sem, encoding="utf-8").read())
    except sqlite3.OperationalError as e:   # partial export (e.g. a test with a few tables)
        print("business views skipped:", e)
db.commit()
db.close()
os.replace(db_path, final_path)
print("done", final_path)

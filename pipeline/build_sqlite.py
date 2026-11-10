"""Build one SQLite database from WDMap XML exports + memo files.

- Every table becomes a SQLite table; every value is stored as TEXT exactly as exported
  (dates stay as WinDev strings like 20200630134209799; profile before converting).
- Column `_row` = 1-based position of the row in the export (WDMap exports in record order).
- Binary memos (.mmo, images/attachments) are written to files and listed in table `_memo_files`
  (table, record number, item index, type, original file name, path, size).
- Table `_tables` holds per-table row counts and status from the export log.

Usage: py build_sqlite.py <xml_dir> <data_dir with .fic/.mmo> <out_dir> [--no-memos] [--only-exported]
"""

import argparse
import hashlib
import sqlite3
import struct
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
from fic_reader import fic_files  # noqa: E402
from hfsql_mmo import Mmo, first_blocks, parse  # noqa: E402
from xmlrows import export_statuses, rows_of  # noqa: E402

from bi import db as bidb  # noqa: E402

BATCH = 5000
MEMO_HEADER = 0xD2  # a .mmo of this size or less holds no memos
META = [
    "CREATE TABLE _tables(name TEXT PRIMARY KEY, rows INTEGER, columns INTEGER, export_status TEXT, fic_bytes INTEGER)",
    (
        "CREATE TABLE _memo_files(tbl TEXT, rec INTEGER, item INTEGER, kind TEXT, ext TEXT, original_name TEXT, "
        "path TEXT, bytes INTEGER, sha1 TEXT)"
    ),
    "CREATE TABLE _memo_texts(tbl TEXT, rec INTEGER, item INTEGER, text TEXT)",
]


def q(n: str) -> str:
    """Quote an SQL identifier."""
    return '"' + n.replace('"', '""') + '"'


class TableLoader:
    """Loads one XML export into a table; columns are added as they are first seen."""

    def __init__(self, db: sqlite3.Connection, name: str) -> None:
        self.db, self.name = db, name
        self.cols: list[str] = []
        self.rows: list[list[Any]] = []
        self.n = 0
        db.execute(f"CREATE TABLE {q(name)} (_row INTEGER PRIMARY KEY)")

    def add(self, row: list[tuple[str, str]]) -> None:
        """Queue one exported row (flushed every BATCH rows)."""
        for c, _ in row:
            if c not in self.cols:
                self.cols.append(c)
                self.db.execute(f"ALTER TABLE {q(self.name)} ADD COLUMN {q(c)} TEXT")
        self.n += 1
        d = dict(row)
        self.rows.append([self.n] + [d.get(c) for c in self.cols])
        if len(self.rows) >= BATCH:
            self.flush()

    def flush(self) -> None:
        """Insert the queued rows (short rows padded with NULL)."""
        if not self.rows:
            return
        width = len(self.cols) + 1
        sql = f"INSERT INTO {q(self.name)} (_row, {', '.join(map(q, self.cols))}) VALUES ({', '.join('?' * width)})"
        self.db.executemany(sql, [r + [None] * (width - len(r)) for r in self.rows])
        self.rows = []


def load_table(db: sqlite3.Connection, name: str, xml: Path) -> tuple[int, int]:
    """Create and fill the table from its XML export; returns (rows, columns)."""
    loader = TableLoader(db, name)
    for row in rows_of(xml, name):
        loader.add(row)
    loader.flush()
    return loader.n, len(loader.cols)


def store_binary(db: sqlite3.Connection, name: str, head: int, r: dict[str, Any], out_dir: Path) -> None:
    """Write a binary memo to memo_files/<table>/ and list it in _memo_files."""
    orig = r["names"][0] or r["names"][1]
    rec = r.get("rec")
    sub = out_dir / "memo_files" / name
    sub.mkdir(parents=True, exist_ok=True)
    p = sub / f"rec{rec if rec is not None else 'NA'}_item{r['item']}_off{head:x}.{r['ext']}"
    p.write_bytes(r["data"])
    db.execute("INSERT INTO _memo_files VALUES (?,?,?,?,?,?,?,?,?)",
               (name, rec, r["item"], r["kind"], r["ext"], orig, str(p.relative_to(out_dir)), len(r["data"]),
                hashlib.sha1(r["data"], usedforsecurity=False).hexdigest()))  # fmt: skip


def memo_heads(name: str, m: Mmo) -> list[int]:
    """First blocks of every memo (none if the file cannot be walked)."""
    try:
        return first_blocks(m)
    except ValueError as e:
        print(name, "memo walk error", e)
        return []


def load_memos(db: sqlite3.Connection, name: str, mmo: Path, out_dir: Path) -> None:
    """Texts into _memo_texts, binaries to files listed in _memo_files."""
    m = Mmo(mmo)
    for h in memo_heads(name, m):
        try:
            r = parse(m.raw(h))
        except (ValueError, struct.error) as e:
            print(name, "memo error", hex(h), e)
            continue
        if r["kind"] == "text":
            db.execute("INSERT INTO _memo_texts VALUES (?,?,?,?)", (name, r.get("rec"), r.get("item"), r["text"]))
        elif r["kind"] == "binary" and r["data"]:
            store_binary(db, name, h, r, out_dir)


def build_tables(db: sqlite3.Connection, xml_dir: Path, data_dir: Path, out_dir: Path, args) -> None:
    """One table per .fic (only exported ones with --only-exported), plus its memos."""
    status = export_statuses(xml_dir)
    fics = fic_files(data_dir)
    for name in sorted(fics, key=str.lower):
        xml = xml_dir / f"{name}.XML"
        if args.only_exported and not xml.exists():
            continue
        n, ncols = load_table(db, name, xml) if xml.exists() else (0, 0)
        fic = fics[name]
        db.execute("INSERT INTO _tables VALUES (?,?,?,?,?)",
                   (name, n, ncols, status.get(name, "not exported"), fic.stat().st_size))  # fmt: skip
        mmo = fic.with_suffix(".mmo")
        if not args.no_memos and mmo.exists() and mmo.stat().st_size > MEMO_HEADER:
            load_memos(db, name, mmo, out_dir)
        db.commit()
        print(f"{name}\t{n}\t{ncols}", flush=True)


def build_views(db_path: Path) -> None:
    """Business views (config from ggest.json next to the database, bi/sql/semantic.sql, bi/sql/ext/*.sql)."""
    bidb.set_db(str(db_path))
    try:
        bidb.build_views()
    except (sqlite3.Error, RuntimeError) as e:  # partial export (e.g. a test with a few tables)
        print("business views skipped:", e)


def main(argv: list[str] | None = None) -> None:
    """CLI: build <out_dir>/data.sqlite, swapped in only when complete."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml_dir")
    ap.add_argument("data_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--no-memos", action="store_true", help="skip .mmo extraction (fast build)")
    ap.add_argument("--only-exported", action="store_true", help="only tables that have an XML export")
    args = ap.parse_args(argv)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    final_path = out_dir / "data.sqlite"
    db_path = out_dir / "data.sqlite.building"  # swapped in at the end: readers never see a half-built file
    db_path.unlink(missing_ok=True)
    db = sqlite3.connect(db_path)
    for sql in META:
        db.execute(sql)
    build_tables(db, Path(args.xml_dir), Path(args.data_dir), out_dir, args)
    db.commit()
    db.close()
    build_views(db_path)
    db_path.replace(final_path)
    print("done", final_path)


if __name__ == "__main__":
    main()

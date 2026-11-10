"""Tolerant streaming reader for WDMap XML exports, plus the export folder's helpers.

WDMap writes `ISO-8859-1` in the header but the bytes are Windows-1252, and values can hold control
characters that strict XML parsers reject, so rows are cut with plain string search.
"""

import html
import re
from collections.abc import Iterable, Iterator
from pathlib import Path

FIELD = re.compile(r"<([A-Za-z_][\w.-]*)>(.*?)</\1>", re.S)
CHUNK = 4 << 20
LOG_FIELDS = 3  # table, bytes, status (then rows, seconds)

Row = list[tuple[str, str]]


def rows_of(path: str | Path, table: str) -> Iterator[Row]:
    """Yield each row as a list of (column, value) pairs, in file order."""
    open_tag, close_tag = f"<{table}>", f"</{table}>"
    buf = ""
    with Path(path).open("rb") as f:
        while chunk := f.read(CHUNK):
            buf += chunk.decode("cp1252", "replace")
            pos = 0
            while (s := buf.find(open_tag, pos)) >= 0:
                e = buf.find(close_tag, s + len(open_tag))
                if e < 0:
                    break
                body = buf[s + len(open_tag) : e]
                pos = e + len(close_tag)
                yield [(m.group(1), html.unescape(m.group(2))) for m in FIELD.finditer(body)]
            buf = buf[pos:]


def first_seen_columns(rows: Iterable[Row]) -> list[str]:
    """Column names in the order they first appear (a NULL item's element is omitted from its row)."""
    seen: dict[str, None] = {}
    for row in rows:
        for c, _ in row:
            seen.setdefault(c)
    return list(seen)


def xml_files(folder: str | Path) -> dict[str, Path]:
    """{lower-case table name: path} of the *.xml files in a WDMap export folder."""
    return {p.stem.lower(): p for p in Path(folder).iterdir() if p.suffix.lower() == ".xml"}


def export_statuses(xml_dir: str | Path) -> dict[str, str]:
    """{table: status} from the export logs (_log_worker*.tsv: table, bytes, status, ...).

    A retry may log the same table again: a success wins over an earlier failure.
    """
    st: dict[str, str] = {}
    if not Path(xml_dir).is_dir():
        return st
    logs = sorted(
        (p for p in Path(xml_dir).iterdir() if p.name.startswith("_log_worker") and p.name.endswith(".tsv")),
        key=lambda p: p.name,
    )
    for lp in logs:
        with lp.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= LOG_FIELDS:
                    name = parts[0].lstrip("\ufeff")
                    if st.get(name) != "OK":
                        st[name] = parts[2]
    return st

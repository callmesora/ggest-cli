"""Builders for tiny synthetic HFSQL files (.fic records, .mmo memos) and WDMap-style XML exports.

Nothing here comes from a real database: names, codes and amounts are invented.
"""

import struct
from dataclasses import dataclass, field
from pathlib import Path

ACTIVE, DELETED = 0x10, 0x80
NO_NEXT = 0xFFFFFFFFFFFFFFFF
MMO_HEADER = 0xD2
PNG_BYTES = bytes([0x89]) + b"PNG" + bytes([13, 10, 26, 10]) + b"pixels"
DESC = bytes(range(0x30, 0x58))  # 40-byte stand-in for the (scrambled) table description


# ---------------------------------------------------------------- .fic
def make_fic(records: list[bytes], stride: int, desc: bytes = DESC) -> bytes:
    """Header + control block + record 0 + records (each `stride` bytes, status byte first)."""
    header = b"PCS\0" + b"\x41" * (0x5A - 4) + desc
    cnt = sum(1 for r in records if r[0] == ACTIVE)
    control = struct.pack("<II", len(records), cnt) + bytes(28) + b"\xff" * 8
    rec0 = b"\x55" * stride
    assert all(len(r) == stride for r in records)
    return header + control + rec0 + b"".join(records)


def rec0_of(desc: bytes = DESC) -> int:
    """Offset of record 0 in a file made by make_fic."""
    return 0x5A + len(desc) + 44


def make_record(stride: int, items: dict[int, bytes], status: int = ACTIVE, recno: int = 1) -> bytes:
    """One record: status, change counter, time, u8, then the items at their offsets."""
    r = bytearray(stride)
    r[0] = status
    struct.pack_into("<HIB", r, 1, recno, 1_700_000_000 + recno, 0)
    for off, b in items.items():
        r[off : off + len(b)] = b
    return bytes(r)


# ---------------------------------------------------------------- .mmo
def text_memo(item: int, rec: int, text: str) -> bytes:
    raw = text.encode("cp1252")
    return struct.pack("<IBIIHI", item, 0x0C, rec, 0, 0, len(raw)) + raw


def binary_memo(item: int, rec: int, data: bytes) -> bytes:
    return struct.pack("<IBIIHI", item, 0x0D, rec, 0, 0, len(data)) + data


def named_memo(item: int, full: str, short: str, blob: bytes) -> bytes:
    f, s = full.encode("cp1252"), short.encode("cp1252")
    names = f + (b"\0" if f else b"") + s + (b"\0" if s else b"")
    return struct.pack("<IBIHH", item, 0x00, 1_700_000_000, len(f), len(s)) + names + blob


def _block(payload: bytes, role: int, nxt: int) -> bytes:
    cls = 4
    while (1 << cls) < 21 + len(payload):
        cls += 1
    head = struct.pack("<HIIBQH", (role << 8) | cls, len(payload), len(payload), 0 if nxt == NO_NEXT else 1, nxt, 0)
    return (head + payload).ljust(1 << cls, b"\0")


def make_mmo(memos: list[bytes], split: int = 0) -> tuple[bytes, list[int]]:
    """A .mmo holding these memo contents; returns (file bytes, offset of each memo's first block).
    With split > 0, memos longer than split bytes are stored as a chain of two blocks."""
    out, heads = bytearray(b"\x00" * MMO_HEADER), []
    for content in memos:
        heads.append(len(out))
        if split and len(content) > split:
            first, rest = content[:split], content[split:]
            first_len = len(_block(first, 0xE4, 0))
            out += _block(first, 0xE4, len(out) + first_len)
            out += _block(rest, 0xD4, NO_NEXT)
        else:
            out += _block(content, 0xF4, NO_NEXT)
    return bytes(out), heads


# ---------------------------------------------------------------- XML
def xml_text(table: str, rows: list[list[tuple[str, str]]]) -> bytes:
    """A WDMap-style export (cp1252, CRLF, tabs)."""

    def esc(v: str) -> str:
        return v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    parts = ['<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>\r\n',
             f'<?xml-stylesheet href="{table}.xsl" type="text/xsl"?>\n<HF_DOCUMENT>\r\n']  # fmt: skip
    for row in rows:
        parts.append(f"\t<{table}>\r\n")
        parts += [f"\t\t<{c}>{esc(v)}</{c}>\r\n" for c, v in row]
        parts.append(f"\t</{table}>\r\n")
    parts.append("</HF_DOCUMENT>\r\n")
    return "".join(parts).encode("cp1252")


# ---------------------------------------------------------------- the sample table
STRIDE = 80
NULL_BIT = 5  # bit of column "note" in the NULL bitmap (byte 8)
# name, offset, size, type
LAYOUT = [
    ("id", 10, 4, "i32"),
    ("name", 14, 16, "str"),
    ("price", 30, 8, "cur4"),
    ("day", 38, 4, "date4"),
    ("stamp", 42, 8, "dt8"),
    ("qty", 50, 2, "i16"),
    ("note", 52, 8, "memo"),
    ("code", 60, 16, "uuid16"),
    ("flag", 76, 1, "u8"),
]
# id, name, price (x 10^4), day (d, m, y), stamp (d, m, y, ms), qty, note (None = NULL), code
ROWS = [
    (101, "Widget A&B", 125000, (31, 1, 2024), (31, 1, 2024, 34215250), 3, "first note", 0x11),
    (102, "Gadget <x>", 0, (1, 2, 2024), (1, 2, 2024, 0), 0, None, 0x22),
    (103, "Caf\xe9 item", 12345678, (0, 0, 0), (0, 0, 0, 0), 12, "", 0x33),
    (104, "Bolt", -32500, (15, 3, 2023), (15, 3, 2023, 86399999), -1, "second\nline", 0x44),
    (105, "Nut", 99990000, (29, 2, 2024), (29, 2, 2024, 1000), 250, None, 0x55),
    (106, "Washer long nm", 5, (9, 9, 2021), (9, 9, 2021, 60000), 7, "third", 0x66),
]


def _uuid(seed: int) -> bytes:
    return bytes((seed + i) % 256 for i in range(16))


def _uuid_text(seed: int) -> str:
    h = _uuid(seed).hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def _cur4(v: int) -> str:
    sign = "-" if v < 0 else ""
    q, r = divmod(abs(v), 10_000)
    return f"{sign}{q}" + (f".{r:04d}".rstrip("0") if r else "")


def _date(d: int, m: int, y: int) -> str:
    return f"{y:04d}{m:02d}{d:02d}" if d or m or y else ""


def _stamp(d: int, m: int, y: int, ms: int) -> str:
    h, r = divmod(ms, 3600000)
    mi, r = divmod(r, 60000)
    s, r = divmod(r, 1000)
    return f"{y:04d}{m:02d}{d:02d}{h:02d}{mi:02d}{s:02d}{r:03d}"


@dataclass
class SampleTable:
    """Sample.fic/.mmo + xml/Sample.XML (+ export log) written to a folder."""

    data_dir: Path
    xml_dir: Path
    xml_rows: list[list[tuple[str, str]]] = field(default_factory=list)

    @property
    def fic(self) -> Path:
        return self.data_dir / "Sample.fic"

    @property
    def xml(self) -> Path:
        return self.xml_dir / "Sample.XML"

    @staticmethod
    def layout() -> dict:
        """The true layout, in the learned-layout format."""
        cols = []
        for name, off, size, typ in LAYOUT:
            col = {"name": name, "offset": off, "size": size, "type": typ}
            if name == "note":
                col["null_bit"] = NULL_BIT
            cols.append(col)
        return {"stride": STRIDE, "rec0": rec0_of(), "desc_sha1": None, "columns": cols,
                "xml_columns": [c[0] for c in LAYOUT]}  # fmt: skip

    @classmethod
    def write(cls, root: Path) -> "SampleTable":
        data_dir, xml_dir = root / "data", root / "xml"
        data_dir.mkdir(parents=True, exist_ok=True)
        xml_dir.mkdir(parents=True, exist_ok=True)
        notes = [r[6] for r in ROWS if r[6]]
        mmo, heads = make_mmo([text_memo(7, i + 1, t) for i, t in enumerate(notes)])
        ptrs = iter(heads)
        records, xml_rows = [], []
        for i, (rid, name, price, day, stamp, qty, note, code) in enumerate(ROWS):
            ptr = 0 if not note else next(ptrs)
            bitmap = 0xFFFF & ~((1 << NULL_BIT) if note is None else 0)
            items = {
                8: struct.pack("<H", bitmap),
                10: struct.pack("<i", rid),
                14: name.encode("cp1252"),
                30: struct.pack("<q", price),
                38: struct.pack("<BBH", *day),
                42: struct.pack("<BBHI", *stamp),
                50: struct.pack("<h", qty),
                52: struct.pack("<Q", ptr),
                60: _uuid(code),
                76: b"\x01",
            }
            records.append(make_record(STRIDE, items, recno=i + 1))
            if i == 2:  # a deleted slot between active records
                records.append(make_record(STRIDE, {10: struct.pack("<i", 999)}, status=DELETED, recno=99))
            row = [("id", str(rid)), ("name", name), ("price", _cur4(price)), ("day", _date(*day)),
                   ("stamp", _stamp(*stamp)), ("qty", str(qty))]  # fmt: skip
            if note is not None:
                row.append(("note", note))
            row += [("code", _uuid_text(code)), ("flag", "1")]
            xml_rows.append(row)
        (data_dir / "Sample.fic").write_bytes(make_fic(records, STRIDE))
        (data_dir / "Sample.mmo").write_bytes(mmo)
        (data_dir / "Sample.ndx").write_bytes(b"index")
        # an empty table and its export status
        (data_dir / "Empty.fic").write_bytes(make_fic([], 16))
        (xml_dir / "Sample.XML").write_bytes(xml_text("Sample", xml_rows))
        (xml_dir / "_log_worker0.tsv").write_text(
            "\ufeffSample\t100\tOK\t6\t0.1\nEmpty\t50\tEMPTY_OR_NO_EXPORT\t0\t0\n", encoding="utf-8"
        )
        return cls(data_dir, xml_dir, xml_rows)

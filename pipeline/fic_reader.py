"""Native reader for gGest HFSQL Classic data files (.fic + .mmo), driven by learned layouts.

Only the plain record area of the .fic is used; the table description in the file header is
scrambled and is NOT read. Instead, each table's physical layout (item -> offset/size/type) was
learned by fic_layout.py from the user's own data and WDMap's XML export of the same rows, and is
stored in layouts/ggest_layouts.json.

File structure used (all little-endian):
  header        'PCS\\0', constant header, two GUID strings, scrambled description (ignored)
  control block ends right before record 0 (rec0):
                  rec0-44  u32  next record id / high-water mark (>= count)
                  rec0-40  u32  number of active records
                  rec0-36  4 zero bytes ... rec0-12  4 zero bytes
                  rec0-8   u64  first free (deleted) slot, all FF = none
  record 0      one stride long, scrambled (ignored)
  records 1..n  fixed stride; byte 0 = status: 0x10 active, 0x80 deleted/free
                +1 u16 change counter, +3 u32 unix time of last change,
                +7 u8, +8 NULL bitmap (1 bit per item, LSB first, cleared = NULL; WDMap then
                omits the element), then the items (fixed width)

Item encodings (values are formatted exactly like WDMap's XML export):
  str      fixed width, cp1252, value = bytes up to the first NUL (padding kept as stored)
  u8/i16/u16/i32/u32/i64   little-endian integers
  cur<k>   i64 fixed-point, value / 10^k (currency/decimal items)
  dec<n>_<k> n-byte signed fixed-point, value / 10^k (n = 2..8; n = 16 for high-precision
           numerics, e.g. dec16_30 = 128-bit integer / 10^30)
  f64/f32  IEEE floats
  date4    u8 day, u8 month, u16 year  -> YYYYMMDD ('' when zero)
  dt8      u8 day, u8 month, u16 year, u32 ms since midnight -> YYYYMMDDHHMMSSmmm
  uuid16   16 raw bytes -> xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (lowercase hex, '' when zero)
  memo     u64 offset of the memo's first block in the .mmo (0 / all FF = no memo); text memos
           are read from the .mmo

Usage:
  py fic_reader.py <table.fic> [--layouts layouts/ggest_layouts.json] [--limit 5] [--xml out.XML]
"""

import argparse
import codecs
import hashlib
import json
import math
import struct
import sys
from collections.abc import Callable, Iterable, Iterator
from decimal import Decimal
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from hfsql_mmo import Mmo, parse  # noqa: E402

DEFAULT_LAYOUTS = HERE / "layouts" / "ggest_layouts.json"

Z4, Z8, FF8 = bytes(4), bytes(8), b"\xff" * 8
ACTIVE = 0x10
SLOT_STATUS = (0x10, 0x80)  # active, deleted/free
NO_MEMO = (0, 0xFFFFFFFFFFFFFFFF)
MIN_STRIDE = 8
CONTROL_BLOCK = 44  # bytes of the control block before record 0
I64_SIZE = 8
STR_PROBE = 4096  # bytes searched for the NUL of a string item of unknown width
EMPTY_DT8 = "00000000000000000"

Framing = dict[str, int]
Layout = dict[str, Any]
Decoder = Callable[[bytes], str | None]


# ---------------------------------------------------------------- framing
def _divisors(n: int) -> list[int]:
    out, i = set(), 1
    while i * i <= n:
        if n % i == 0:
            out.add(i)
            out.add(n // i)
        i += 1
    return sorted(out)


def _control_block(data: bytes, p: int) -> tuple[int, int] | None:
    """(high-water mark, active count) if a control block ends at p, else None."""
    fh = data[p - 8 : p]
    if fh != FF8 and (fh[4:] != Z4 or fh == Z8):
        return None
    if data[p - 36 : p - 32] != Z4 or data[p - 12 : p - 8] != Z4:
        return None
    return struct.unpack_from("<II", data, p - CONTROL_BLOCK)


def _stride_at(data: bytes, p: int, cnt: int, strides: Iterable[int]) -> int | None:
    """First stride whose slots after record 0 hold exactly cnt active records."""
    size = len(data)
    span = size - p
    for s in strides:
        if s < MIN_STRIDE or span % s or span // s - 1 < cnt:
            continue
        if data[size - s] not in SLOT_STATUS or data[p + s] not in SLOT_STATUS:
            continue
        if data[p + s :: s].count(ACTIVE) == cnt:
            return s
    return None


def _framing_at(data: bytes, p: int, stride: int | None) -> Framing | None:
    """The framing with record 0 at p, if the control block and the record statuses agree."""
    cb = _control_block(data, p)
    if cb is None:
        return None
    hw, cnt = cb
    span = len(data) - p
    if cnt * 8 > span or hw < cnt:
        return None
    if cnt == 0:  # empty table: only record 0
        return {"rec0": p, "stride": stride, "slots": 0, "count": 0} if stride and span == stride else None
    s = _stride_at(data, p, cnt, [stride] if stride else _divisors(span))
    return None if s is None else {"rec0": p, "stride": s, "slots": span // s - 1, "count": cnt}


def frame_candidates(data: bytes, stride: int | None = None, limit: int = 0x20000) -> list[Framing]:
    """All self-consistent (rec0, stride) framings: the control block's active-record count
    must equal the number of slots whose status byte is 0x10."""
    found = (_framing_at(data, p, stride) for p in range(0x60, min(len(data), limit)))
    return [f for f in found if f is not None]


def frame(data: bytes, stride: int | None = None, rec0: int | None = None) -> Framing | None:
    """Best framing; with a known stride (from the layout) this is fast."""
    if rec0 is not None and stride:
        size = len(data)
        if rec0 < size and (size - rec0) % stride == 0 and rec0 >= CONTROL_BLOCK:
            cnt = struct.unpack_from("<I", data, rec0 - 40)[0]
            if data[rec0 + stride :: stride].count(ACTIVE) == cnt:
                return {"rec0": rec0, "stride": stride, "slots": (size - rec0) // stride - 1, "count": cnt}
    c = frame_candidates(data, stride)
    return c[0] if c else None


def active_records(data: bytes, fr: Framing) -> Iterator[tuple[int, bytes]]:
    """(record number, record bytes) of every active slot."""
    p, s = fr["rec0"], fr["stride"]
    for i in range(1, fr["slots"] + 1):
        o = p + s * i
        if data[o] == ACTIVE:
            yield i, data[o : o + s]


# ---------------------------------------------------------------- value formatting
def _strip_fraction(s: str) -> str:
    return s.rstrip("0").rstrip(".") if "." in s else s


def fmt_decimal(d: Decimal) -> str:
    """Decimal -> WDMap text: no exponent, no trailing zeros, '0' for zero."""
    if not d:
        return "0"
    return _strip_fraction(format(d.normalize(), "f"))


def fmt_float(x: float) -> str:
    """f64 -> shortest repr, without exponent or a trailing '.0'."""
    if x == 0:
        return "0"
    if not math.isfinite(x):
        return str(x)
    s = repr(x)
    if "e" in s or "E" in s:
        s = format(Decimal(s), "f")
    return s.removesuffix(".0")


def _fmt_general(x: float, digits: int) -> str:
    if x == 0:
        return "0"
    s = f"{x:.{digits}g}"
    if "e" in s:
        s = format(Decimal(s), "f")
    return _strip_fraction(s)


def fmt_float15(x: float) -> str:
    """f64 with 15 significant digits."""
    return _fmt_general(x, 15)


def fmt_float32(x: float) -> str:
    """f32 with 7 significant digits."""
    return _fmt_general(x, 7)


def _fmt_hms(ms: int) -> str:
    h, r = divmod(ms, 3600000)
    mi, r = divmod(r, 60000)
    s, ms = divmod(r, 1000)
    return f"{h:02d}{mi:02d}{s:02d}{ms:03d}"


def _fmt_dt8(d: int, m: int, y: int, ms: int) -> str:
    if not (d or m or y or ms):
        return EMPTY_DT8
    return f"{y:04d}{m:02d}{d:02d}{_fmt_hms(ms)}"


_POW = {k: Decimal(10) ** k for k in range(39)}
_IPOW = {k: 10**k for k in range(39)}
_INT_FMT = {"u8": "<B", "i8": "<b", "i16": "<h", "u16": "<H", "i32": "<i", "u32": "<I", "i64": "<q", "u64": "<Q"}

FIXED = {  # type -> size
    "u8": 1, "i8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8,
    "f32": 4, "f64": 8, "f64g": 8, "date4": 4, "dt8": 8, "time4": 4, "memo": 8, "bmemo": 8, "uuid16": 16,
}  # fmt: skip
for _k in range(39):
    FIXED[f"cur{_k}"] = 8
    for _n in (2, 3, 4, 5, 6, 7, 8, 16):
        FIXED[f"dec{_n}_{_k}"] = _n


def fixed_point_spec(typ: str) -> tuple[int, int]:
    """(bytes, decimals) of a cur<k> / dec<n>_<k> type."""
    if typ.startswith("cur"):
        return 8, int(typ[3:])
    n, k = typ[3:].split("_")
    return int(n), int(k)


def size_of(col: Layout) -> int:
    """Width of a layout column in the record."""
    return col["size"] if col["type"] in ("str", "ustr") else FIXED[col["type"]]


# ---------------------------------------------------------------- decoding
def _dec_str(rec: bytes, o: int, size: int, _memo: "MemoFile | None") -> str | None:
    b = rec[o : o + size] if size else rec[o : o + STR_PROBE]
    z = b.find(0)
    if z < 0:
        if not size:
            return None
        z = len(b)
    return b[:z].decode("cp1252", "replace")


def _dec_ustr(rec: bytes, o: int, size: int, _memo: "MemoFile | None") -> str:
    b = rec[o : o + size]
    for i in range(0, len(b) - 1, 2):
        if b[i] == 0 and b[i + 1] == 0:
            b = b[:i]
            break
    return b.decode("utf-16-le", "replace")


def _dec_u8(rec: bytes, o: int, _size: int, _memo: "MemoFile | None") -> str:
    return str(rec[o])


def _int_decoder(fmt: str) -> Callable[..., str]:
    up = struct.Struct(fmt).unpack_from
    return lambda rec, o, _size, _memo: str(up(rec, o)[0])


def _dec_fixed_point(rec: bytes, o: int, typ: str) -> str:
    n, k = fixed_point_spec(typ)
    if typ.startswith("cur"):
        v = struct.unpack_from("<q", rec, o)[0]
    else:
        v = int.from_bytes(rec[o : o + n], "little", signed=True)
    return fmt_decimal(Decimal(v) / _POW[k])


def _dec_date4(rec: bytes, o: int, _size: int, _memo: "MemoFile | None") -> str:
    d, m, y = struct.unpack_from("<BBH", rec, o)
    return f"{y:04d}{m:02d}{d:02d}" if d or m or y else ""


def _dec_dt8(rec: bytes, o: int, _size: int, _memo: "MemoFile | None") -> str:
    return _fmt_dt8(*struct.unpack_from("<BBHI", rec, o))


def _dec_uuid16(rec: bytes, o: int, _size: int, _memo: "MemoFile | None") -> str:
    b = rec[o : o + 16]
    if not any(b):
        return ""
    h = b.hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def _dec_time4(rec: bytes, o: int, _size: int, _memo: "MemoFile | None") -> str:
    return _fmt_hms(struct.unpack_from("<I", rec, o)[0])


def _dec_memo(rec: bytes, o: int, _size: int, memo: "MemoFile | None") -> str | None:
    ptr = struct.unpack_from("<Q", rec, o)[0]
    if ptr in NO_MEMO:
        return ""
    return None if memo is None else memo.text(ptr)


def _float_decoder(fmt: str, show: Callable[[float], str]) -> Callable[..., str]:
    return lambda rec, o, _size, _memo: show(struct.unpack_from(fmt, rec, o)[0])


_DECODERS: dict[str, Callable[..., str | None]] = {
    "str": _dec_str,
    "ustr": _dec_ustr,
    **{t: _int_decoder(f) for t, f in _INT_FMT.items()},
    "u8": _dec_u8,
    "f64": _float_decoder("<d", fmt_float),
    "f64g": _float_decoder("<d", fmt_float15),
    "f32": _float_decoder("<f", fmt_float32),
    "date4": _dec_date4,
    "dt8": _dec_dt8,
    "uuid16": _dec_uuid16,
    "time4": _dec_time4,
    "memo": _dec_memo,
}


def decode(rec: bytes, o: int, typ: str, size: int = 0, memo: "MemoFile | None" = None) -> str | None:
    """Decode one item. Returns the WDMap-formatted string, or None if it cannot be decoded."""
    f = _DECODERS.get(typ)
    if f is not None:
        return f(rec, o, size, memo)
    if typ.startswith(("dec", "cur")):
        return _dec_fixed_point(rec, o, typ)
    raise ValueError(typ)


def _fmt_scaled(v: int, k: int) -> str:
    """Integer v / 10^k formatted like WDMap (no exponent, no trailing zeros)."""
    if k == 0 or v == 0:
        return str(v)
    sign = "-" if v < 0 else ""
    q, r = divmod(abs(v), _IPOW[k])
    if not r:
        return sign + str(q)
    frac = str(r).rjust(k, "0").rstrip("0")
    return f"{sign}{q}.{frac}"


def _compile_str(o: int, size: int) -> Decoder:
    end = o + size

    def f(r: bytes) -> str:
        b = r[o:end]
        z = b.find(0)
        return (b if z < 0 else b[:z]).decode("cp1252", "replace")

    return f


def _compile_fixed_point(typ: str, o: int) -> Decoder:
    n, k = fixed_point_spec(typ)
    if n == I64_SIZE:
        up = struct.Struct("<q").unpack_from
        return lambda r: _fmt_scaled(up(r, o)[0], k)
    end = o + n
    return lambda r: _fmt_scaled(int.from_bytes(r[o:end], "little", signed=True), k)


def _compile_dt8(o: int) -> Decoder:
    up = struct.Struct("<BBHI").unpack_from
    return lambda r: _fmt_dt8(*up(r, o))


def compile_decoder(typ: str, o: int, size: int = 0, memo: "MemoFile | None" = None) -> Decoder:
    """Fast decoder for one item: f(record bytes) -> WDMap-formatted string (or None)."""
    if typ == "str":
        return _compile_str(o, size)
    if typ in _INT_FMT:
        up = struct.Struct(_INT_FMT[typ]).unpack_from
        return lambda r: str(up(r, o)[0])
    if typ.startswith(("cur", "dec")):
        return _compile_fixed_point(typ, o)
    if typ == "dt8":
        return _compile_dt8(o)
    return lambda r: decode(r, o, typ, size, memo)


class MemoFile:
    """Text memos of one table, read lazily from the .mmo through record pointers."""

    MIN_SIZE = 0xD2  # header only: no memos

    def __init__(self, path: str | Path | None) -> None:
        self.path = path
        self.m: Mmo | None = None
        self.cache: dict[int, str | None] = {}
        if path and Path(path).exists() and Path(path).stat().st_size > self.MIN_SIZE:
            self.m = Mmo(path)

    def text(self, ptr: int) -> str | None:
        """Text of the memo starting at ptr (None if missing, binary or unreadable)."""
        if ptr not in self.cache:
            self.cache[ptr] = self._read(ptr)
        return self.cache[ptr]

    def _read(self, ptr: int) -> str | None:
        if self.m is None or ptr >= self.m.size:
            return None
        try:
            r = parse(self.m.raw(ptr))
        except (ValueError, struct.error, OSError):
            return None
        return r["text"] if r["kind"] == "text" else None


# ---------------------------------------------------------------- layouts
def load_layouts(path: str | Path = DEFAULT_LAYOUTS) -> dict[str, Any]:
    """The learned layouts document ({"tables": {name: layout}, ...})."""
    return json.loads(Path(path).read_text(encoding="utf-8"))


def fic_files(folder: str | Path) -> dict[str, Path]:
    """{table name: path} of the .fic files in a folder."""
    return {p.stem: p for p in Path(folder).iterdir() if p.suffix.lower() == ".fic"}


def desc_hash(data: bytes, rec0: int) -> str:
    """SHA-1 of the header block between the GUIDs and the control block (the table description).
    The block is only hashed, never decoded: any change to it means the table definition changed."""
    return hashlib.sha1(data[0x5A : rec0 - CONTROL_BLOCK], usedforsecurity=False).hexdigest()


def check_fingerprint(fic_path: str | Path, layout: Layout) -> tuple[bool, str, Framing | None]:
    """Returns (ok, reason, framing)."""
    data = Path(fic_path).read_bytes()
    fr = frame(data, layout["stride"], layout.get("rec0"))
    if fr is None:
        return False, "framing with the learned stride failed (record size changed?)", None
    if fr["rec0"] != layout.get("rec0"):
        return False, f"record 0 moved {layout.get('rec0')} -> {fr['rec0']} (table description changed?)", fr
    if layout.get("desc_sha1") and desc_hash(data, fr["rec0"]) != layout["desc_sha1"]:
        return False, "table description block changed (gGest update?)", fr
    return True, "", fr


def _null_mask(col: Layout) -> tuple[int, int] | None:
    """(byte offset, bit mask) of a column's NULL bit, if it has one."""
    if "null_bit" not in col:
        return None
    return 8 + col["null_bit"] // 8, 1 << (col["null_bit"] % 8)


def _column_readers(fic_path: Path, layout: Layout) -> list[tuple[str, Decoder, tuple[int, int] | None]]:
    has_memo = any(c["type"] == "memo" for c in layout["columns"])
    memo = MemoFile(fic_path.with_suffix(".mmo")) if has_memo else None
    return [
        (c["name"], compile_decoder(c["type"], c["offset"], size_of(c), memo), _null_mask(c)) for c in layout["columns"]
    ]


def read_table(
    fic_path: str | Path, layout: Layout, data: bytes | None = None, with_recno: bool = False
) -> Iterator[Any]:
    """Yield rows as lists of (column, value) pairs, in physical record order,
    formatted like WDMap's XML export ((recno, row) with with_recno)."""
    fic_path = Path(fic_path)
    if data is None:
        data = fic_path.read_bytes()
    fr = frame(data, layout["stride"], layout.get("rec0"))
    if fr is None:
        raise ValueError(f"{fic_path}: cannot frame records with stride {layout['stride']}")
    cols = _column_readers(fic_path, layout)
    for recno, rec in active_records(data, fr):
        # a NULL item (cleared bit) is left out, like WDMap does
        row = [(name, "" if (v := f(rec)) is None else v) for name, f, nb in cols if not nb or rec[nb[0]] & nb[1]]
        yield (recno, row) if with_recno else row


def xml_escape(s: str) -> str:
    """Escape &, < and > like WDMap."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _undefined_as_byte(err: UnicodeEncodeError) -> tuple[bytes, int]:
    """Encode error handler: U+FFFD stands for a cp1252 byte without a character (0x81, 0x8D, 0x8F,
    0x90, 0x9D); write an undefined byte back so the file reads exactly like WDMap's export
    (xmlrows decodes it as U+FFFD again)."""
    s = err.object[err.start : err.end]
    return bytes(0x81 if ch == "\ufffd" else 0x3F for ch in s), err.end


codecs.register_error("wdmap_undefined", _undefined_as_byte)


def write_xml(path: str | Path, table: str, rows: Iterable[list[tuple[str, str]]]) -> int:
    """Write rows in WDMap's XML export format (cp1252 bytes, CRLF, tab indentation), so that
    xmlrows.rows_of() / build_sqlite.py read them exactly like a WDMap export. Returns the row count."""
    n = 0
    crlf, tab = "\r\n", "\t"
    with Path(path).open("w", encoding="cp1252", errors="wdmap_undefined", newline="") as f:
        f.write('<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>' + crlf)
        f.write(f'<?xml-stylesheet href="{table}.xsl" type="text/xsl"?>' + "\n" + "<HF_DOCUMENT>" + crlf)
        for row in rows:
            parts = [f"{tab}<{table}>{crlf}"]
            parts += [f"{tab}{tab}<{c}>{xml_escape(v)}</{c}>{crlf}" for c, v in row]
            parts.append(f"{tab}</{table}>{crlf}")
            f.write("".join(parts))
            n += 1
        f.write("</HF_DOCUMENT>" + crlf)
    return n


def find_layout(layouts: dict[str, Layout], table: str) -> Layout | None:
    """Layout of a table, matching its name case-insensitively when there is no exact match."""
    return layouts.get(table) or {k.lower(): v for k, v in layouts.items()}.get(table.lower())


def main(argv: list[str] | None = None) -> None:
    """CLI: print a few rows of one table, or write all of them as a WDMap-style XML file."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fic")
    ap.add_argument("--layouts", default=str(DEFAULT_LAYOUTS))
    ap.add_argument("--limit", type=int, default=5, help="rows to print (0 = all)")
    ap.add_argument("--xml", help="write all rows to this XML file (WDMap format) instead of printing")
    a = ap.parse_args(argv)
    table = Path(a.fic).stem
    lay = find_layout(load_layouts(a.layouts)["tables"], table)
    if not lay or not lay.get("columns"):
        sys.exit(f"no layout for {table}")
    ok, why, _ = check_fingerprint(a.fic, lay)
    if not ok:
        print(f"warning: {why}", file=sys.stderr)
    if a.xml:
        n = write_xml(a.xml, table, read_table(a.fic, lay))
        print(f"{n} rows -> {a.xml}")
        return
    for i, row in enumerate(read_table(a.fic, lay)):
        if a.limit and i >= a.limit:
            break
        print(dict(row))


if __name__ == "__main__":
    main()

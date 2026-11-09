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
import json
import os
import struct
import sys
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
DEFAULT_LAYOUTS = os.path.join(HERE, "layouts", "ggest_layouts.json")

Z4, Z8, FF8 = bytes(4), bytes(8), b"\xff" * 8
ACTIVE = 0x10


# ---------------------------------------------------------------- framing
def _divisors(n):
    out, i = set(), 1
    while i * i <= n:
        if n % i == 0:
            out.add(i)
            out.add(n // i)
        i += 1
    return sorted(out)


def frame_candidates(data, stride=None, limit=0x20000):
    """All self-consistent (rec0, stride) framings: the control block's active-record count
    must equal the number of slots whose status byte is 0x10."""
    L = len(data)
    found = []
    for p in range(0x60, min(L, limit)):
        fh = data[p - 8:p]
        if fh != FF8 and (fh[4:] != Z4 or fh == Z8):
            continue
        if data[p - 36:p - 32] != Z4 or data[p - 12:p - 8] != Z4:
            continue
        hw, cnt = struct.unpack_from("<II", data, p - 44)
        span = L - p
        if cnt * 8 > span or hw < cnt:
            continue
        if cnt == 0:
            if stride and span == stride:      # empty table: only record 0
                found.append({"rec0": p, "stride": stride, "slots": 0, "count": 0})
            continue
        for s in ([stride] if stride else _divisors(span)):
            if s < 8 or span % s or span // s - 1 < cnt:
                continue
            if data[L - s] not in (0x10, 0x80) or data[p + s] not in (0x10, 0x80):
                continue
            if data[p + s::s].count(ACTIVE) == cnt:
                found.append({"rec0": p, "stride": s, "slots": span // s - 1, "count": cnt})
                break
    return found


def frame(data, stride=None, rec0=None):
    """Best framing; with a known stride (from the layout) this is fast."""
    if rec0 is not None and stride:
        L = len(data)
        if rec0 < L and (L - rec0) % stride == 0 and rec0 >= 44:
            cnt = struct.unpack_from("<I", data, rec0 - 40)[0]
            if data[rec0 + stride::stride].count(ACTIVE) == cnt:
                return {"rec0": rec0, "stride": stride, "slots": (L - rec0) // stride - 1, "count": cnt}
    c = frame_candidates(data, stride)
    return c[0] if c else None


def active_records(data, fr):
    p, s = fr["rec0"], fr["stride"]
    for i in range(1, fr["slots"] + 1):
        o = p + s * i
        if data[o] == ACTIVE:
            yield i, data[o:o + s]


# ---------------------------------------------------------------- value formatting
def fmt_decimal(d):
    """Decimal -> WDMap text: no exponent, no trailing zeros, '0' for zero."""
    if not d:
        return "0"
    s = format(d.normalize(), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def fmt_float(x):
    if x == 0:
        return "0"
    if x != x or x in (float("inf"), float("-inf")):
        return str(x)
    s = repr(x)
    if "e" in s or "E" in s:
        s = format(Decimal(s), "f")
    if s.endswith(".0"):
        s = s[:-2]
    return s


def fmt_float15(x):
    if x == 0:
        return "0"
    s = "%.15g" % x
    if "e" in s:
        s = format(Decimal(s), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def fmt_float32(x):
    if x == 0:
        return "0"
    s = "%.7g" % x
    if "e" in s:
        s = format(Decimal(s), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


_POW = {k: Decimal(10) ** k for k in range(0, 39)}

FIXED = {  # type -> size
    "u8": 1, "i8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8,
    "f32": 4, "f64": 8, "f64g": 8, "date4": 4, "dt8": 8, "time4": 4, "memo": 8, "bmemo": 8, "uuid16": 16,
}
for _k in range(0, 39):
    FIXED[f"cur{_k}"] = 8
    for _n in (2, 3, 4, 5, 6, 7, 8, 16):
        FIXED[f"dec{_n}_{_k}"] = _n


def size_of_type(typ):
    return FIXED[typ]


def size_of(col):
    return col["size"] if col["type"] in ("str", "ustr") else FIXED[col["type"]]


def decode(rec, o, typ, size=0, memo=None):
    """Decode one item. Returns the WDMap-formatted string, or None if it cannot be decoded."""
    if typ == "str":
        b = rec[o:o + size] if size else rec[o:o + 4096]
        z = b.find(0)
        if z < 0:
            if not size:
                return None
            z = len(b)
        return b[:z].decode("cp1252", "replace")
    if typ == "ustr":
        b = rec[o:o + size]
        for i in range(0, len(b) - 1, 2):
            if b[i] == 0 and b[i + 1] == 0:
                b = b[:i]
                break
        return b.decode("utf-16-le", "replace")
    if typ == "u8":
        return str(rec[o])
    if typ == "i8":
        return str(struct.unpack_from("<b", rec, o)[0])
    if typ == "i16":
        return str(struct.unpack_from("<h", rec, o)[0])
    if typ == "u16":
        return str(struct.unpack_from("<H", rec, o)[0])
    if typ == "i32":
        return str(struct.unpack_from("<i", rec, o)[0])
    if typ == "u32":
        return str(struct.unpack_from("<I", rec, o)[0])
    if typ == "i64":
        return str(struct.unpack_from("<q", rec, o)[0])
    if typ == "u64":
        return str(struct.unpack_from("<Q", rec, o)[0])
    if typ.startswith("dec"):
        n, k = typ[3:].split("_")
        v = int.from_bytes(rec[o:o + int(n)], "little", signed=True)
        return fmt_decimal(Decimal(v) / _POW[int(k)])
    if typ.startswith("cur"):
        v = struct.unpack_from("<q", rec, o)[0]
        return fmt_decimal(Decimal(v) / _POW[int(typ[3:])])
    if typ == "f64":
        return fmt_float(struct.unpack_from("<d", rec, o)[0])
    if typ == "f64g":
        return fmt_float15(struct.unpack_from("<d", rec, o)[0])
    if typ == "f32":
        return fmt_float32(struct.unpack_from("<f", rec, o)[0])
    if typ == "date4":
        d, m, y = struct.unpack_from("<BBH", rec, o)
        if not (d or m or y):
            return ""
        return f"{y:04d}{m:02d}{d:02d}"
    if typ == "dt8":
        d, m, y, ms = struct.unpack_from("<BBHI", rec, o)
        if not (d or m or y or ms):
            return "00000000000000000"
        h, r = divmod(ms, 3600000)
        mi, r = divmod(r, 60000)
        s, ms = divmod(r, 1000)
        return f"{y:04d}{m:02d}{d:02d}{h:02d}{mi:02d}{s:02d}{ms:03d}"
    if typ == "uuid16":
        b = rec[o:o + 16]
        if not any(b):
            return ""
        h = b.hex()
        return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"
    if typ == "time4":
        ms = struct.unpack_from("<I", rec, o)[0]
        h, r = divmod(ms, 3600000)
        mi, r = divmod(r, 60000)
        s, ms = divmod(r, 1000)
        return f"{h:02d}{mi:02d}{s:02d}{ms:03d}"
    if typ == "memo":
        ptr = struct.unpack_from("<Q", rec, o)[0]
        if ptr in (0, 0xFFFFFFFFFFFFFFFF):
            return ""
        if memo is None:
            return None
        return memo.text(ptr)
    raise ValueError(typ)


def _fmt_scaled(v, k):
    """Integer v / 10^k formatted like WDMap (no exponent, no trailing zeros)."""
    if k == 0 or v == 0:
        return str(v)
    q, r = divmod(abs(v), _IPOW[k])
    if not r:
        return ("-" if v < 0 else "") + str(q)
    frac = str(r).rjust(k, "0").rstrip("0")
    return ("-" if v < 0 else "") + f"{q}.{frac}"


_IPOW = {k: 10 ** k for k in range(0, 39)}
_INT_FMT = {"u8": "<B", "i8": "<b", "i16": "<h", "u16": "<H", "i32": "<i", "u32": "<I", "i64": "<q", "u64": "<Q"}


def compile_decoder(typ, o, size=0, memo=None):
    """Fast decoder for one item: f(record bytes) -> WDMap-formatted string (or None)."""
    if typ == "str":
        end = o + size

        def f(r):
            b = r[o:end]
            z = b.find(0)
            return (b if z < 0 else b[:z]).decode("cp1252", "replace")
        return f
    if typ in _INT_FMT:
        up = struct.Struct(_INT_FMT[typ]).unpack_from
        return lambda r: str(up(r, o)[0])
    if typ.startswith("cur") or typ.startswith("dec"):
        if typ.startswith("cur"):
            n, k = 8, int(typ[3:])
        else:
            n, k = (int(x) for x in typ[3:].split("_"))
        end = o + n
        if n == 8:
            up = struct.Struct("<q").unpack_from
            return lambda r: _fmt_scaled(up(r, o)[0], k)
        return lambda r: _fmt_scaled(int.from_bytes(r[o:end], "little", signed=True), k)
    if typ == "dt8":
        up = struct.Struct("<BBHI").unpack_from

        def f(r):
            d, m, y, ms = up(r, o)
            if not (d or m or y or ms):
                return "00000000000000000"
            h, x = divmod(ms, 3600000)
            mi, x = divmod(x, 60000)
            s, x = divmod(x, 1000)
            return f"{y:04d}{m:02d}{d:02d}{h:02d}{mi:02d}{s:02d}{x:03d}"
        return f
    return lambda r: decode(r, o, typ, size, memo)


class MemoFile:
    """Text memos of one table, read lazily from the .mmo through record pointers."""

    def __init__(self, path):
        self.path = path
        self.m = None
        self.cache = {}
        if path and os.path.exists(path) and os.path.getsize(path) > 0xD2:
            from hfsql_mmo import Mmo
            self.m = Mmo(path)

    def text(self, ptr):
        if ptr in self.cache:
            return self.cache[ptr]
        t = None
        if self.m is not None and ptr < self.m.size:
            try:
                from hfsql_mmo import parse
                r = parse(self.m.raw(ptr))
                if r["kind"] == "text":
                    t = r["text"]
            except Exception:
                t = None
        self.cache[ptr] = t
        return t


# ---------------------------------------------------------------- layouts
def load_layouts(path=DEFAULT_LAYOUTS):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def desc_hash(data, rec0):
    """SHA-1 of the header block between the GUIDs and the control block (the table description).
    The block is only hashed, never decoded: any change to it means the table definition changed."""
    import hashlib
    return hashlib.sha1(data[0x5A:rec0 - 44]).hexdigest()


def fingerprint(data, fr):
    """Per-table schema fingerprint: record stride, position of record 0 (depends on the size of
    the table description) and a hash of the description block."""
    return {"stride": fr["stride"], "rec0": fr["rec0"], "desc_sha1": desc_hash(data, fr["rec0"])}


def check_fingerprint(fic_path, layout):
    """Returns (ok, reason, framing)."""
    with open(fic_path, "rb") as f:
        data = f.read()
    fr = frame(data, layout["stride"], layout.get("rec0"))
    if fr is None:
        return False, "framing with the learned stride failed (record size changed?)", None
    if fr["rec0"] != layout.get("rec0"):
        return False, f"record 0 moved {layout.get('rec0')} -> {fr['rec0']} (table description changed?)", fr
    if layout.get("desc_sha1") and desc_hash(data, fr["rec0"]) != layout["desc_sha1"]:
        return False, "table description block changed (gGest update?)", fr
    return True, "", fr


def read_table(fic_path, layout, data=None, with_recno=False):
    """Yield rows as lists of (column, value) pairs, in physical record order,
    formatted like WDMap's XML export."""
    if data is None:
        with open(fic_path, "rb") as f:
            data = f.read()
    fr = frame(data, layout["stride"], layout.get("rec0"))
    if fr is None:
        raise ValueError(f"{fic_path}: cannot frame records with stride {layout['stride']}")
    mmo = os.path.splitext(fic_path)[0] + ".mmo"
    memo = MemoFile(mmo) if any(c["type"] == "memo" for c in layout["columns"]) else None
    cols = [(c["name"], compile_decoder(c["type"], c["offset"], size_of(c), memo),
             (8 + c["null_bit"] // 8, 1 << (c["null_bit"] % 8)) if "null_bit" in c else None)
            for c in layout["columns"]]
    for recno, rec in active_records(data, fr):
        row = []
        for name, f, nb in cols:
            if nb and not rec[nb[0]] & nb[1]:
                continue           # NULL: WDMap leaves the element out
            v = f(rec)
            row.append((name, "" if v is None else v))
        yield (recno, row) if with_recno else row


def xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _undefined_as_byte(err):
    """Encode error handler: U+FFFD stands for a cp1252 byte without a character (0x81, 0x8D, 0x8F,
    0x90, 0x9D); write an undefined byte back so the file reads exactly like WDMap's export
    (xmlrows decodes it as U+FFFD again)."""
    s = err.object[err.start:err.end]
    return bytes(0x81 if ch == "�" else 0x3F for ch in s), err.end


codecs.register_error("wdmap_undefined", _undefined_as_byte)


def write_xml(path, table, rows):
    """Write rows in WDMap's XML export format (cp1252 bytes, CRLF, tab indentation), so that
    xmlrows.rows_of() / build_sqlite.py read them exactly like a WDMap export."""
    n = 0
    crlf, tab = "\r\n", "\t"
    with open(path, "w", encoding="cp1252", errors="wdmap_undefined", newline="") as f:
        f.write('<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>' + crlf)
        f.write(f'<?xml-stylesheet href="{table}.xsl" type="text/xsl"?>' + "\n" + "<HF_DOCUMENT>" + crlf)
        for row in rows:
            parts = [f"{tab}<{table}>{crlf}"]
            for c, v in row:
                parts.append(f"{tab}{tab}<{c}>{xml_escape(v)}</{c}>{crlf}")
            parts.append(f"{tab}</{table}>{crlf}")
            f.write("".join(parts))
            n += 1
        f.write("</HF_DOCUMENT>" + crlf)
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fic")
    ap.add_argument("--layouts", default=DEFAULT_LAYOUTS)
    ap.add_argument("--limit", type=int, default=5, help="rows to print (0 = all)")
    ap.add_argument("--xml", help="write all rows to this XML file (WDMap format) instead of printing")
    a = ap.parse_args()
    table = os.path.splitext(os.path.basename(a.fic))[0]
    layouts = load_layouts(a.layouts)["tables"]
    lay = layouts.get(table) or {k.lower(): v for k, v in layouts.items()}.get(table.lower())
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
        print({c: v for c, v in row})


if __name__ == "__main__":
    main()

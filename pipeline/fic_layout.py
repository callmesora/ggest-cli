r"""Learn the physical record layout of every gGest table from known plaintext.

For each table we have the raw .fic (and .mmo) and WDMap's XML export of the same rows. The
learner never touches the scrambled table description in the .fic header; it only looks at the
plain record area:

  1. framing   - record 0 position and stride from the control block (fic_reader.frame_candidates),
                 checked against the XML row count
  2. alignment - pair each active record with its XML row through a column whose values are
                 unique (or a combination of columns), found by scanning offsets x encodings
  3. layout    - for every XML column, the (offset, encoding) pairs that reproduce its XML value in
                 every sampled row are candidates; columns are placed on the record without overlap
                 (unique candidates first, then constraint propagation, then XML-neighbour order for
                 columns whose values do not tell where they are, e.g. always 0); string widths and
                 integer sizes are taken from the gap up to the next placed item; every placed
                 column is then verified on ALL rows (failures are banned and placement repeated)
  4. output    - layouts/ggest_layouts.json: per table stride, rec0 (fingerprint), columns
                 [{name, offset, size, type, constant_in_data}], unmatched columns, validation.

Columns whose value never varies in the current data ("constant_in_data") reproduce today's
data exactly, but their position is a best guess; validate_reader.py will catch it if future data
disagrees with WDMap.

Usage:
  py fic_layout.py --data C:\\...\\BDW --xml C:\\...\\export\\xml [--tables a,b] [--out layouts/ggest_layouts.json]
"""

import argparse
import collections
import hashlib
import json
import random
import re
import struct
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fic_reader import (  # noqa: E402
    FIXED,
    MemoFile,
    active_records,
    compile_decoder,
    decode,
    desc_hash,
    fic_files,
    fixed_point_spec,
    frame_candidates,
)
from xmlrows import export_statuses, first_seen_columns, rows_of, xml_files  # noqa: E402

LAYOUT_VERSION = 1
DEFAULT_OUT = HERE / "layouts" / "ggest_layouts.json"
INT_TYPES = ["u8", "i16", "i32", "i64", "i8", "u16", "u32"]
DEC_TYPES = (
    [f"cur{k}" for k in (7, 6, 4, 2, 3, 5, 8)]
    + [f"dec{n}_{k}" for n in (6, 4, 2, 3, 5, 7) for k in (7, 6, 4, 2, 3, 5, 8)]
    + [f"dec16_{k}" for k in (30, 20, 10, 8, 7, 6, 4, 2)]
)
FLOAT_TYPES = ["f64", "f64g", "f32"]
# preference when the data cannot tell encodings apart (lower = preferred)
PRIOR = {
    t: i
    for i, t in enumerate(
        [
            "str",
            "dt8",
            "date4",
            "memo",
            "i64",
            "i32",
            "u8",
            "i16",
            "cur7",
            "cur6",
            "f64",
            "dec6_6",
            *INT_TYPES,
            *DEC_TYPES,
            *FLOAT_TYPES,
            "time4",
        ]
    )
}
NUMRE = re.compile(r"-?\d+(\.\d+)?$")
INTRE = re.compile(r"-?\d+$")
UUIDRE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
BITS = {"u8": 8, "i8": 7, "i16": 15, "u16": 16, "i32": 31, "u32": 32, "i64": 63}
INT_FMT = {"u8": "<B", "i8": "<b", "i16": "<h", "u16": "<H", "i32": "<i", "u32": "<I", "i64": "<q"}
# encodings that are never used to pair records with XML rows
NOT_KEYS = {*FLOAT_TYPES, "time4", "memo"}
# encodings kept as they are when a constant value cannot tell same-size encodings apart
ALWAYS_KEEP = ("str", "memo", "dt8", "date4", "uuid16", "time4")
# (type, values tested: "ne" = non-empty values / "vs" = all non-NULL values, test)
PATTERN_TYPES: list[tuple[str, str, Callable[[str], Any]]] = [
    ("date4", "ne", lambda v: len(v) == 8 and v.isdigit()),  # noqa: PLR2004 - YYYYMMDD
    ("dt8", "vs", lambda v: len(v) == 17 and v.isdigit()),  # noqa: PLR2004 - YYYYMMDDHHMMSSmmm
    ("time4", "ne", lambda v: len(v) == 9 and v.isdigit()),  # noqa: PLR2004 - HHMMSSmmm
    ("uuid16", "ne", UUIDRE.match),
]
RECORD_HEADER = 8  # status, counter, time, u8 - then the NULL bitmap
UNIQUE_KEYS_TRIED = 12
MAX_KEY_COLUMNS = 10
ALIGN_SAMPLE = 40
COMPOSITE_SAMPLE = 400
LAYOUT_SAMPLE = 60
RARE_VALUES = 16
PLACE_ATTEMPTS = 6
FEW_CANDIDATES = 3
UNKNOWN_PRIOR = 99
PREFERRED_DEC_SIZE = 8  # currency-sized decimals first


def log(*a: object) -> None:
    """Print progress immediately."""
    print(*a, flush=True)


def size_hint(typ: str) -> int:
    """Fixed size of an encoding (0 for strings)."""
    return FIXED.get(typ, 0)


def prior(t: str) -> int:
    """Preference of an encoding when the data cannot tell (lower = preferred)."""
    return PRIOR.get(t, UNKNOWN_PRIOR)


# ---------------------------------------------------------------- XML values -> encodings
def canonical_number(v: str) -> bool:
    """True if v is written the way the reader formats numbers (no leading zeros, no trailing
    decimal zeros), so that a numeric encoding can reproduce it."""
    neg = v.startswith("-")
    w = v[1:] if neg else v
    ip, _, fp = w.partition(".")
    if len(ip) > 1 and ip.startswith("0"):
        return False
    if fp and fp.endswith("0"):
        return False
    return not (neg and w == "0")


def _int_options(ne: list[str]) -> list[str]:
    mx = max(abs(int(v)) for v in ne)
    neg = any(v.startswith("-") for v in ne)
    return [t for t in INT_TYPES if not (t.startswith("u") and neg) and mx < (1 << BITS[t])]


def _numeric_options(vs: list[str], ne: list[str]) -> list[str]:
    if not ne or len(ne) != len(vs) or not all(NUMRE.match(v) and canonical_number(v) for v in ne):
        return []
    ints = _int_options(ne) if all(INTRE.match(v) for v in ne) else []
    return ints + DEC_TYPES + FLOAT_TYPES


def type_options(values: list[str | None]) -> list[str]:
    """Encodings worth trying for a column, from its XML values."""
    vs = [v for v in values if v is not None]
    pools = {"vs": vs, "ne": [v for v in vs if v != ""]}
    opts = ["str", *_numeric_options(vs, pools["ne"])]
    opts += [t for t, pool, test in PATTERN_TYPES if pools[pool] and all(test(v) for v in pools[pool])]
    opts.append("memo")
    return opts


def _enc_str(v: str) -> bytes:
    return v.encode("cp1252") + b"\0"


def _enc_date4(v: str) -> bytes:
    if v == "":
        return bytes(4)
    return struct.pack("<BBH", int(v[6:8]), int(v[4:6]), int(v[:4]))


def _ms(hh: str, mi: str, ss: str, mmm: str) -> int:
    return int(hh) * 3600000 + int(mi) * 60000 + int(ss) * 1000 + int(mmm)


def _enc_dt8(v: str) -> bytes:
    ms = _ms(v[8:10], v[10:12], v[12:14], v[14:17])
    return struct.pack("<BBHI", int(v[6:8]), int(v[4:6]), int(v[:4]), ms)


def _enc_uuid16(v: str) -> bytes:
    return bytes(16) if v == "" else bytes.fromhex(v.replace("-", ""))


def _enc_time4(v: str) -> bytes:
    return struct.pack("<I", _ms(v[0:2], v[2:4], v[4:6], v[6:9]))


def _enc_fixed_point(v: str, typ: str) -> bytes | None:
    n, k = fixed_point_spec(typ)
    d = Decimal(v) * (Decimal(10) ** k)
    if d != d.to_integral_value():
        return None
    return int(d).to_bytes(n, "little", signed=True)


_ENCODERS: dict[str, Callable[[str], bytes]] = {
    "str": _enc_str,
    "date4": _enc_date4,
    "dt8": _enc_dt8,
    "uuid16": _enc_uuid16,
    "time4": _enc_time4,
}


def encode(v: str, typ: str) -> bytes | None:
    """Bytes an item of this type holds for XML value v (None if not representable / not exact).
    Floats and memos are not encoded: they are compared through decode()."""
    try:
        if typ in INT_FMT:
            return struct.pack(INT_FMT[typ], int(v))
        if typ.startswith(("cur", "dec")):
            return _enc_fixed_point(v, typ)
        enc = _ENCODERS.get(typ)
        return None if enc is None else enc(v)
    except (ValueError, InvalidOperation, struct.error, OverflowError, UnicodeEncodeError):
        return None


def key_types(values: list[str]) -> list[str]:
    """Encodings that can pair records with XML rows through these values."""
    return [t for t in type_options(values) if t not in NOT_KEYS]


def distinguishable(opts: list[str], v0: str | None) -> list[str]:
    """For a column with one constant value: keep the preferred encoding among those that hold
    the same bytes in the same size (the data cannot tell them apart)."""
    keep: dict[Any, str] = {}
    for t in sorted(opts, key=prior):
        if t in ALWAYS_KEEP:
            keep[t] = t
        elif t in FLOAT_TYPES:
            keep.setdefault((t, size_hint(t)), t)
        elif v0 is not None and (e := encode(v0, t)) is not None:
            keep.setdefault((size_hint(t), e), t)
    return list(keep.values())


def xml_column_order(rows: list[list[tuple[str, str]]]) -> list[str]:
    """Column order of the export: a NULL item's element is omitted, so take the order of the
    longest row and add columns never seen there in first-seen order."""
    cols = [c for c, _ in max(rows, key=len)] if rows else []
    seen = set(cols)
    for c in first_seen_columns(rows):
        if c not in seen:
            seen.add(c)
            cols.append(c)
    return cols


def int_width(mx: int) -> int:
    """Bytes an integer column needs for magnitudes up to mx."""
    for width, bits in ((1, 7), (2, 15), (4, 31)):
        if mx < (1 << bits):
            return width
    return 8


def plausible_fixed(fixed: list[str], room: int, mx: int) -> list[str]:
    """Encodings of a varying fixed-size column that best use `room` bytes: 8-byte decimals, else
    integers by magnitude, else whatever fits."""
    fitting = [t for t in fixed if size_hint(t) <= room]
    ints = [t for t in fitting if t in BITS]
    if ints:
        want = int_width(mx)
        return sorted(ints, key=lambda t: (abs(size_hint(t) - want), prior(t)))[:1]
    return _prefer_decimals([t for t in fitting if t.startswith(("cur", "dec"))]) or fitting or fixed


def _prefer_decimals(decs: list[str]) -> list[str]:
    """8-byte decimals first, else the widest."""
    return [t for t in decs if size_hint(t) == PREFERRED_DEC_SIZE] or sorted(decs, key=lambda t: -size_hint(t))


def finish_column(c: str, pos: int, ts: list[str], room: int, minw: int, varies: bool) -> dict[str, Any]:
    """Layout entry of a placed column: strings take the room up to the next item; fixed types
    take the largest encoding that fits that room (an exact fit only if the column varies)."""
    if "str" in ts and len(ts) == 1:
        return {"name": c, "offset": pos, "size": max(room, minw), "type": "str"}
    t = _fixed_choice([t for t in ts if t != "str"], room, varies)
    return {"name": c, "offset": pos, "size": size_hint(t), "type": t}


def _fixed_choice(fixed: list[str], room: int, varies: bool) -> str:
    exact = [t for t in fixed if size_hint(t) == room] if varies else []
    fit = exact or [t for t in fixed if size_hint(t) <= room] or fixed
    return sorted(fit, key=prior)[0]


# ---------------------------------------------------------------- 2. alignment
def _unique_mapping(recs: list[bytes], o: int, typ: str, index: dict[str, int]) -> list[int] | None:
    """XML row of every record if the item at o decodes to a distinct key value in each."""
    m = []
    for r in recs:
        v = decode(r, o, typ, 0)
        if v not in index:
            return None
        m.append(index[v])
    return m if len(set(m)) == len(recs) else None


def key_offsets(typ: str, stride: int) -> range:
    """Offsets where a key item of this type may start (byte 7 onwards, inside the record)."""
    return range(7, stride - max(size_hint(typ), 1) + 1)


def align_sample(recs: list[bytes]) -> list[bytes]:
    """Up to 40 records spread over the table."""
    return recs[:: max(1, len(recs) // ALIGN_SAMPLE)][:ALIGN_SAMPLE]


def unique_columns(cols: list[str], vals: dict[str, list[str | None]], n: int) -> list[str]:
    """Columns whose n values are all distinct and non-empty, longest values first."""
    uniq = [c for c in cols if None not in vals[c] and "" not in vals[c] and len(set(vals[c])) == n]
    uniq.sort(key=lambda c: -sum(len(v) for v in vals[c][:200]))
    return uniq


def _unique_item(values: list[str], recs: list[bytes], sample: list[bytes], stride: int):
    """(mapping, offset, type) of an item holding this unique column, else None."""
    index = {v: i for i, v in enumerate(values)}
    for typ in key_types(values):
        for o in key_offsets(typ, stride):
            if all(decode(r, o, typ, 0) in index for r in sample):
                m = _unique_mapping(recs, o, typ, index)
                if m is not None:
                    return m, o, typ
    return None


def _align_unique(recs, cols, vals, stride) -> tuple[list[int], dict[str, Any]] | None:
    """Pair records and rows through one column whose values are all distinct."""
    sample = align_sample(recs)
    for c in unique_columns(cols, vals, len(recs))[:UNIQUE_KEYS_TRIED]:
        hit = _unique_item(vals[c], recs, sample, stride)
        if hit is not None:
            m, o, typ = hit
            return m, {"by": [c], "offset": o, "type": typ}
    return None


def _key_column_hit(values, recs, sample, big, stride) -> tuple[int, str, list[str | None]] | None:
    """(offset, type, decoded values) of an item whose values are exactly the column's multiset."""
    present = set(values)
    target = collections.Counter(values)
    for typ in key_types(values):
        for o in key_offsets(typ, stride):
            if not _maybe_key(o, typ, sample, big, present):
                continue
            full = [decode(r, o, typ, 0) for r in recs]
            if collections.Counter(full) == target:
                return o, typ, full
    return None


def _maybe_key(o: int, typ: str, sample: list[bytes], big: list[bytes], present: set) -> bool:
    """Item at o takes column values (more than one) in the sample, and only column values in a
    larger sample."""
    dec = [decode(r, o, typ, 0) for r in sample]
    if not (all(d in present for d in dec) and len(set(dec)) > 1):
        return False
    return all(decode(r, o, typ, 0) in present for r in big)


def _composite_keys(recs, cols, vals, stride) -> list[tuple[str, tuple]]:
    """Columns (most distinct values first) found in the records, until together they are unique."""
    n = len(recs)
    sample = align_sample(recs)
    big = recs[:: max(1, n // COMPOSITE_SAMPLE)]
    found: list[tuple[str, tuple]] = []
    for c in sorted(cols, key=lambda c: -len(set(vals[c]))):
        if found and len(set(zip(*[vals[f] for f, _ in found], strict=True))) == n:
            break
        if len(set(vals[c])) < 2 or None in vals[c]:  # noqa: PLR2004 - a key needs two values
            continue
        hit = _key_column_hit(vals[c], recs, sample, big, stride)
        if hit:
            found.append((c, hit))
            if len(found) >= MAX_KEY_COLUMNS:
                break
    return found


def _composite_mapping(found, vals, n) -> tuple[list[int], dict[str, Any]] | None:
    """Pair records and rows through the combined key of several columns."""
    rk = list(zip(*[h[2] for _, h in found], strict=True))
    xk = list(zip(*[vals[c] for c, _ in found], strict=True))
    cnt = collections.Counter(xk)
    if collections.Counter(rk) != cnt:
        return None
    pool = collections.defaultdict(list)
    for j, k in enumerate(xk):
        pool[k].append(j)
    m = [pool[k].pop(0) for k in rk]
    amb = [i for i, k in enumerate(rk) if cnt[k] > 1]
    how = {"by": [c for c, _ in found], "composite": True, "unique_rows": n - len(amb), "ambiguous_rows": amb}
    return m, how


def align(recs, cols, vals, stride) -> tuple[list[int] | None, dict[str, Any] | None]:
    """XML row index of every record, and how the pairing was found ((None, None) if it fails)."""
    if len(recs) == 1:
        return [0], {"by": [], "single_row": True}
    res = _align_unique(recs, cols, vals, stride)
    if res is None:
        found = _composite_keys(recs, cols, vals, stride)
        res = _composite_mapping(found, vals, len(recs)) if found else None
    return res if res is not None else (None, None)


# ---------------------------------------------------------------- 3. layout: candidates
@dataclass
class Probe:
    """How to look for one encoding of a column: `needle` = bytes searched in the probe row (None
    = try every offset), `encs` = expected bytes per row, `kind` = how a row is compared."""

    kind: str  # "fuzzy" (decoded text), "str" (bytes + NUL), "decode" (decoded value), "bytes"
    needle: bytes | None
    encs: list[bytes | None]


def make_probe(t: str, pv: str, values: list[str], fuzzy: bool) -> Probe | None:
    """Probe of encoding t for the values of a column (pv = most telling value); None if the
    values cannot be held in this encoding."""
    if t == "str":
        return _str_probe(pv, values, fuzzy)
    if t in FLOAT_TYPES or t == "memo":
        return _decode_probe(t, pv, len(values))
    needle = encode(pv, t)
    encs = [encode(v, t) for v in values]
    if needle is None or any(x is None for x in encs):
        return None
    return Probe("bytes", needle, encs)


def _str_probe(pv: str, values: list[str], fuzzy: bool) -> Probe:
    if fuzzy:  # undefined cp1252 bytes in the XML: compare decoded text, not bytes
        return Probe("fuzzy", None, [None] * len(values))
    return Probe("str", pv.encode("cp1252", "replace") + b"\0", [v.encode("cp1252", "replace") for v in values])


def _decode_probe(t: str, pv: str, n: int) -> Probe | None:
    """Floats and memos are compared decoded; only an f64 value can be searched as bytes."""
    needle = None
    if t == "f64":
        try:
            needle = struct.pack("<d", float(pv))
        except (ValueError, OverflowError):
            return None
    return Probe("decode", needle, [None] * n)


def find_all(data: bytes, needle: bytes) -> list[int]:
    """Every offset of needle in data (overlapping)."""
    poss, i = [], data.find(needle)
    while i >= 0:
        poss.append(i)
        i = data.find(needle, i + 1)
    return poss


def known_values(xc: list[str | None], rows: list[int], recs: list[bytes]) -> list[tuple[bytes, str]]:
    """(record, XML value) of the given rows whose value is not NULL (recs = the rows' records)."""
    return [(r, xc[i]) for r, i in zip(recs, rows, strict=True) if xc[i] is not None]


def probe_row(pairs: list[tuple[bytes, str]]) -> tuple[bytes, str]:
    """The (record, value) whose value tells most: not empty or 0, then the longest."""
    return max(pairs, key=lambda rv: (rv[1] not in ("", "0"), len(rv[1])))


def item_positions(probe_row: bytes, needle: bytes | None, sz: int, stride: int) -> list[int]:
    """Offsets after the record header where an item of size sz fits: where the needle occurs in
    the probe row, or everywhere when there is no needle."""
    width = max(sz, 1)
    poss = find_all(probe_row, needle) if needle is not None else range(RECORD_HEADER, stride - width + 1)
    return [pos for pos in poss if pos >= RECORD_HEADER and pos + width <= stride]


# ---------------------------------------------------------------- 3. layout: placement
class Assigner:
    """Places columns on the record without overlap, from their candidate (offset, types)."""

    def __init__(self, cols, cands, minw, varies, banned, stride, maxabs=None) -> None:
        self.cols, self.cands, self.minw, self.varies = cols, cands, minw, varies
        self.banned, self.stride, self.maxabs = banned, stride, maxabs or {}
        self.occ = bytearray(stride)
        self.occ[0:RECORD_HEADER] = b"\1" * RECORD_HEADER
        self.placed: dict[str, tuple[int, list[str]]] = {}
        self.idx = {c: i for i, c in enumerate(cols)}
        # per column: {pos: [(size, type), ...] sorted by size}
        self.bysize = {c: {pos: self._by_size(c, ts) for pos, ts in cc.items()} for c, cc in cands.items()}

    def _by_size(self, c: str, ts: list[str]) -> list[tuple[int, str]]:
        return [(sz, t) for sz, _, t in sorted((self.smin(c, t), prior(t), t) for t in ts)]

    def smin(self, c: str, t: str) -> int:
        """Smallest width of column c in encoding t."""
        return self.minw[c] if t == "str" else size_hint(t)

    def run(self) -> dict[str, tuple[int, list[str]]]:
        """{column: (offset, types)} of every column that could be placed."""
        self.place_constrained()
        self.settle_fixed_widths()
        self.place_constants()
        return self.placed

    def options(self, c: str) -> list[tuple[int, list[str]]]:
        """Free (offset, types) for column c."""
        res = []
        for pos, lst in self.bysize.get(c, {}).items():
            ok = []
            for sz, t in lst:
                if pos + sz > self.stride or any(self.occ[pos : pos + sz]):
                    break  # larger sizes overlap too
                if (c, pos, t) not in self.banned:
                    ok.append(t)
            if ok:
                res.append((pos, ok))
        return res

    def put(self, c: str, pos: int, ts: list[str]) -> None:
        """Place column c at pos and mark its smallest width as occupied."""
        self.placed[c] = (pos, ts)
        s = min(self.smin(c, t) for t in ts)
        self.occ[pos : pos + s] = b"\1" * s

    def _neighbour(self, c: str, step: int) -> str | None:
        i = self.idx[c] + step
        while 0 <= i < len(self.cols):
            if self.cols[i] in self.placed:
                return self.cols[i]
            i += step
        return None

    def neighbour_choice(self, c: str, o: list[tuple[int, list[str]]]) -> tuple[int, list[str]]:
        """Option right after the previous placed XML column, else right before the next one, else
        the option that explains the most bytes (e.g. an 8-digit string beats a 4-byte date that
        only matches the date part of a datetime), then the lowest offset."""
        return (
            self._after_previous(c, o)
            or self._before_next(c, o)
            or max(o, key=lambda x: (max(self.smin(c, t) for t in x[1]), -x[0]))
        )

    def _after_previous(self, c: str, o: list[tuple[int, list[str]]]) -> tuple[int, list[str]] | None:
        prev = self._neighbour(c, -1)
        if prev is None:
            return None
        pp, pts = self.placed[prev]
        ends = {pp + self.smin(prev, t) for t in pts}
        return next(((pos, ts) for pos, ts in o if pos in ends), None)

    def _before_next(self, c: str, o: list[tuple[int, list[str]]]) -> tuple[int, list[str]] | None:
        nxt = self._neighbour(c, 1)
        if nxt is None:
            return None
        npos = self.placed[nxt][0]
        for pos, ts in o:
            fit = [t for t in ts if pos + self.smin(c, t) == npos]
            if fit:
                return pos, fit
        return None

    def _propagate(self, remaining: list[str]) -> dict[str, list[tuple[int, list[str]]]] | None:
        """Place every column with a single option and drop those with none; returns the options of
        the others, or None if anything changed."""
        progress, opts_now = False, {}
        for c in list(remaining):
            o = self.options(c)
            if len(o) == 1:
                self.put(c, *o[0])
            if len(o) <= 1:
                remaining.remove(c)
                progress = True
            else:
                opts_now[c] = o
        return None if progress else opts_now

    def place_constrained(self) -> None:
        """Columns whose values vary (or with few candidates): constraint propagation, then the
        most constrained column first."""
        cands, varies = self.cands, self.varies
        remaining = [c for c in self.cols if cands.get(c) and (varies[c] or len(cands[c]) <= FEW_CANDIDATES)]
        while remaining:
            opts_now = self._propagate(remaining)
            if opts_now is None:
                continue
            c = min(remaining, key=lambda c: (len(opts_now[c]), self.idx[c]))
            self.put(c, *self.neighbour_choice(c, sorted(opts_now[c])))
            remaining.remove(c)

    def settle_fixed_widths(self) -> None:
        """Give each varying fixed-size column its most plausible width before constants are
        placed: exact fit up to the next item, else 8-byte decimals, else ints by magnitude."""
        starts = sorted(p for p, _ in self.placed.values())
        for c, (pos, ts) in list(self.placed.items()):
            fixed = [t for t in ts if t != "str"]
            if not fixed or "str" in ts:
                continue
            nxt = next((x for x in starts if x > pos), self.stride)
            pick = self._exact_fit(c, fixed, nxt, nxt - pos) or plausible_fixed(fixed, nxt - pos, self.maxabs.get(c, 0))
            pick = sorted(pick, key=prior)[:1]
            self.placed[c] = (pos, pick)
            sz = size_hint(pick[0])
            self.occ[pos : pos + sz] = b"\x01" * sz

    def _exact_fit(self, c: str, fixed: list[str], nxt: int, room: int) -> list[str]:
        """Encodings filling the room exactly, trusted only when the next item is this column's XML
        successor (otherwise the gap may hold columns that are constant in the data)."""
        i = self.idx[c] + 1
        succ = self.cols[i] if i < len(self.cols) else None
        trust = succ is not None and succ in self.placed and self.placed[succ][0] == nxt
        return [t for t in fixed if size_hint(t) == room] if trust else []

    def place_constants(self) -> None:
        """Columns whose position is not identifiable from values: XML order, next to neighbours."""
        for c in sorted(self.cols, key=lambda c: (len(self.cands.get(c) or ()) > FEW_CANDIDATES, self.idx[c])):
            if c in self.placed or not self.cands.get(c):
                continue
            o = self.options(c)
            if o:
                self.put(c, *self.neighbour_choice(c, sorted(o)))


@dataclass
class ColumnStats:
    """What the XML values of one column tell before placement."""

    opts: list[str]
    minw: int  # cp1252 width of the longest value + NUL
    varies: bool
    rows: list[int]  # rows used to find candidates: the sample + rows with rare values
    maxabs: int | None = None


def first_rows_per_value(xc: list[str | None], use: list[int], limit: int = RARE_VALUES) -> list[int]:
    """Row of the first occurrence of each distinct value (up to limit values)."""
    seen: dict[str | None, int] = {}
    for i in use:
        v = xc[i]
        if v not in seen:
            seen[v] = i
            if len(seen) >= limit:
                break
    return list(seen.values())


def column_stats(xc: list[str | None], use: list[int], sample: list[int]) -> ColumnStats:
    """Encodings, minimum width, variability and probe rows of one column."""
    vs = [xc[i] for i in use]
    opts = type_options(vs)
    minw = max((len(v.encode("cp1252", "replace")) for v in vs if v is not None), default=0) + 1
    varies = len(set(vs)) > 1
    if not varies and vs:
        opts = distinguishable(opts, vs[0])
    maxabs = max(abs(int(v)) for v in vs if v) if {"i64", "u8", "i32"} & set(opts) else None
    rare = first_rows_per_value(xc, use) if varies else []
    return ColumnStats(opts, minw, varies, sorted(set(sample) | set(rare)), maxabs)


def best_per_size(ts: list[str], minw: int) -> list[str]:
    """For a constant column: the preferred encoding of each width."""
    best: dict[int, str] = {}
    for t in sorted(ts, key=prior):
        best.setdefault(minw if t == "str" else size_hint(t), t)
    return list(best.values())


# ---------------------------------------------------------------- the table
@dataclass
class Table:
    """One table being learned: its .fic bytes, memo file and WDMap XML export."""

    name: str
    fic: str | Path
    xml: str | Path
    data: bytes = field(init=False, repr=False)
    memo: MemoFile = field(init=False, repr=False)
    fr: dict[str, int] | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        self.data = Path(self.fic).read_bytes()
        self.memo = MemoFile(Path(self.fic).with_suffix(".mmo"))
        self._constb: list[bool] = []
        self._vcache: dict[tuple, bool] = {}

    # ---------------------------------------------------------- 1. framing
    def frame(self, nrows: int) -> dict[str, int] | None:
        """Framing whose active-record count matches the XML (else the first one found)."""
        cands = frame_candidates(self.data)
        good = [c for c in cands if c["count"] == nrows]
        self.fr = good[0] if good else (cands[0] if cands else None)
        return self.fr

    def align(self, recs, cols, vals) -> tuple[list[int] | None, dict[str, Any] | None]:
        """XML row index of every record (see align())."""
        return align(recs, cols, vals, self.fr["stride"])

    def _xml(self, order: Callable) -> tuple[list, list[str], dict[str, list[str | None]]]:
        rows = list(rows_of(self.xml, self.name))
        cols = order(rows)
        dicts = [dict(r) for r in rows]
        return rows, cols, {c: [d.get(c) for d in dicts] for c in cols}

    # ---------------------------------------------------------- 3. layout
    def learn(self) -> dict[str, Any]:
        """The learned layout of the table (with "error" when it cannot be learned)."""
        t0 = time.time()
        rows, cols, vals = self._xml(xml_column_order)
        out = {"table": self.name, "layout_version": LAYOUT_VERSION, "xml_rows": len(rows), "xml_columns": cols}
        error = self._learn_into(out, len(rows), cols, vals)
        if error:
            out["error"] = error
            return out
        out["learn_seconds"] = round(time.time() - t0, 1)
        return out

    def _learn_into(self, out: dict[str, Any], nrows: int, cols: list[str], vals) -> str | None:
        """Fill out with framing, alignment and columns; returns an error message, if any."""
        fr = self.frame(nrows)
        if not fr:
            return "no framing"
        out.update({"stride": fr["stride"], "rec0": fr["rec0"], "desc_sha1": desc_hash(self.data, fr["rec0"]),
                    "slots": fr["slots"], "active": fr["count"]})  # fmt: skip
        if fr["count"] != nrows:
            return f"active records {fr['count']} != XML rows {nrows}"
        return self._layout_into(out, [r for _, r in active_records(self.data, fr)], cols, vals)

    def _layout_into(self, out: dict[str, Any], recs: list[bytes], cols: list[str], vals) -> str | None:
        m, how = self.align(recs, cols, vals)
        if m is None:
            return "alignment failed"
        out["alignment"] = {k: v for k, v in how.items() if k != "ambiguous_rows"}
        amb = set(how.get("ambiguous_rows", []))
        xv = {c: [vals[c][m[i]] for i in range(len(recs))] for c in cols}
        use = [i for i in range(len(recs)) if i not in amb]
        if not use:
            return "no unambiguous rows"
        out.update(self.place(recs, cols, xv, use))
        self.null_bits(out, recs, xv)
        return None

    def null_bits(self, out: dict[str, Any], recs: list[bytes], xv: dict[str, list[str | None]]) -> None:
        """WDMap omits the element of a NULL item. NULL is a cleared bit in the bitmap that starts at
        record offset 8 (LSB first). For every column that is NULL in some rows, find the bit whose
        cleared state matches exactly the rows where the element is missing."""
        nbits = 8 * min(64, max(1, self.fr["stride"] - RECORD_HEADER))
        for col in out.get("columns", []):
            miss = [v is None for v in xv[col["name"]]]
            if not any(miss):
                continue
            bit = null_bit(recs, miss, nbits)
            if bit is None:
                col["null_bit_unknown"] = True
            else:
                col["null_bit"] = bit

    def update_null_bits(self) -> tuple[list[bytes], dict[str, list[str | None]]] | None:
        """Records and their XML values for recomputing null bits of an already learned layout."""
        rows, cols, vals = self._xml(first_seen_columns)
        self.frame(len(rows))
        recs = [r for _, r in active_records(self.data, self.fr)]
        m, _ = self.align(recs, cols, vals)
        if m is None:
            return None
        return recs, {c: [vals[c][m[i]] for i in range(len(recs))] for c in cols}

    def candidates(self, c, opts, xv, sample, srecs, stride, constant=False) -> dict[int, list[str]]:
        """{pos: [types]} where the type reproduces the XML value of column c in every sampled row."""
        pairs = known_values(xv[c], sample, srecs)
        if not pairs:
            return {}
        pr, pv = probe_row(pairs)
        values = [v for _, v in pairs]
        fuzzy = any("\ufffd" in v for v in values)
        out = collections.defaultdict(list)
        for t in opts:
            probe = make_probe(t, pv, values, fuzzy)
            if probe is None:
                continue
            sz = size_hint(t)
            for pos in item_positions(pr, probe.needle, sz, stride):
                check = self._rows_to_check(t, pos, pairs, sz, constant)
                if check is not None and self._all_match(probe, check, pos, t, sz, stride):
                    out[pos].append(t)
        return dict(out)

    def _rows_to_check(self, t, pos, pairs, sz, constant) -> list | None:
        """Rows to compare at pos. For a constant column the probe row decides, and the bytes must
        not vary across the sample (memo pointers differ even for equal texts)."""
        if not constant or t == "memo":
            return pairs
        w = len(pairs[0][1]) + 1 if t == "str" else sz
        return pairs[:1] if all(self._constb[pos : pos + w]) else None

    def _all_match(self, probe: Probe, check, pos: int, t: str, sz: int, stride: int) -> bool:
        return all(
            self._matches(probe.kind, r, v, ev, pos, t, sz, stride)
            for (r, v), ev in zip(check, probe.encs, strict=False)
        )

    def _matches(self, kind, r, v, ev, pos, t, sz, stride) -> bool:
        if kind == "fuzzy":
            return decode(r, pos, "str", 0) == v
        if kind == "str":
            return r.startswith(ev, pos) and not (pos + len(ev) < stride and r[pos + len(ev)] != 0)
        if kind == "bytes":
            return r[pos : pos + sz] == ev
        if t == "memo" and v == "" and r[pos : pos + 8] not in (bytes(8), b"\xff" * 8):
            return False
        return decode(r, pos, t, sz, self.memo) == v

    def _sample(self, use: list[int]) -> list[int]:
        rnd = random.Random(1)  # noqa: S311 - deterministic sampling, not security
        return sorted(set(use[:5] + use[-5:] + rnd.sample(use, min(len(use), LAYOUT_SAMPLE))))

    def _all_candidates(self, recs, cols, xv, stats: dict[str, ColumnStats]) -> dict[str, dict[int, list[str]]]:
        stride = self.fr["stride"]
        cands = {}
        for c in cols:
            st = stats[c]
            cands[c] = self.candidates(c, st.opts, xv, st.rows, [recs[i] for i in st.rows], stride,
                                       constant=not st.varies)  # fmt: skip
        for c in cols:
            if not stats[c].varies:
                for pos, ts in cands[c].items():
                    cands[c][pos] = best_per_size(ts, stats[c].minw)
        return cands

    def place(self, recs, cols, xv, use) -> dict[str, Any]:
        """Columns placed on the record and verified on every usable row."""
        stride = self.fr["stride"]
        sample = self._sample(use)
        srecs = [recs[i] for i in sample]
        stats = {c: column_stats(xv[c], use, sample) for c in cols}
        self._constb = [len({r[p] for r in srecs}) == 1 for p in range(stride)]
        cands = self._all_candidates(recs, cols, xv, stats)
        varies = {c: s.varies for c, s in stats.items()}
        result = self._place_verified(cols, cands, stats, recs, xv, use)
        for col in result:
            col["constant_in_data"] = not varies[col["name"]]
        failed = [c["name"] for c in self._verify(result, recs, xv, use, record=True)]
        return {"columns": result, "unmatched": unplaced(cols, result), "failed_columns": failed,
                "validated_rows": len(use)}  # fmt: skip

    def _place_verified(self, cols, cands, stats: dict[str, ColumnStats], recs, xv, use) -> list[dict[str, Any]]:
        """Place and verify; columns that fail are banned from their spot and placement is repeated."""
        stride = self.fr["stride"]
        minw = {c: s.minw for c, s in stats.items()}
        varies = {c: s.varies for c, s in stats.items()}
        maxabs = {c: s.maxabs for c, s in stats.items() if s.maxabs is not None}
        banned: set[tuple[str, int, str]] = set()
        for _ in range(PLACE_ATTEMPTS):
            placed = Assigner(cols, cands, minw, varies, banned, stride, maxabs).run()
            result = self._finish(cols, placed, minw, stride, varies)
            bad = self._verify(result, recs, xv, use)
            if not bad:
                break
            banned.update((col["name"], col["offset"], col["type"]) for col in bad)
        return result

    @staticmethod
    def _finish(cols, placed, minw, stride, varies) -> list[dict[str, Any]]:
        starts = sorted(pos for pos, _ in placed.values())
        columns = []
        for c in cols:
            if c in placed:
                pos, ts = placed[c]
                room = next((s for s in starts if s > pos), stride) - pos
                columns.append(finish_column(c, pos, ts, room, minw[c], varies.get(c, True)))
        return columns

    def _verify(self, columns, recs, xv, use, record=False) -> list[dict[str, Any]]:
        """Columns whose decoded value differs from the XML in some row (cached per placement;
        with record=True every row is checked and the mismatch count and an example are stored)."""
        bad = []
        for col in columns:
            key = (col["name"], col["offset"], col["type"], col["size"])
            if not record and key in self._vcache:
                if not self._vcache[key]:
                    bad.append(col)
                continue
            f = compile_decoder(col["type"], col["offset"], col["size"], self.memo)
            mism, ex = count_mismatches(f, xv[col["name"]], recs, use, stop_at_first=not record)
            self._vcache[key] = not mism
            if mism:
                if record:
                    col["mismatches"] = mism
                    col["example"] = ex
                bad.append(col)
        return bad


def unplaced(cols: list[str], columns: list[dict[str, Any]]) -> list[str]:
    """XML columns without a layout column."""
    names = {c["name"] for c in columns}
    return [c for c in cols if c not in names]


def count_mismatches(f, xc, recs, use, stop_at_first) -> tuple[int, list[str] | None]:
    """(rows where f(record) differs from the non-NULL XML value, [xml, decoded] of the first)."""
    mism, ex = 0, None
    for i in use:
        v = xc[i]
        if v is None:
            continue
        d = f(recs[i])
        if d != v:
            mism += 1
            if ex is None:
                ex = [v[:80], (d if d is not None else "<None>")[:80]]
            if stop_at_first:
                break
    return mism, ex


def null_bit(recs: list[bytes], miss: list[bool], nbits: int) -> int | None:
    """First bitmap bit that is cleared exactly in the records where the value is missing."""
    for bit in range(nbits):
        o, m = RECORD_HEADER + bit // 8, 1 << (bit % 8)
        if all((not (r[o] & m)) == x for r, x in zip(recs, miss, strict=False)):
            return bit
    return None


# ---------------------------------------------------------------- 4. output
def empty_entry(name: str, fic: Path, status: str) -> dict[str, Any]:
    """Layout entry of a table without a usable XML export."""
    ent = {"table": name, "xml_rows": 0, "status": status, "columns": []}
    if status == "EMPTY_OR_NO_EXPORT":
        # an empty table is read natively as empty only while its .fic stays byte-identical
        ent["empty_sha1"] = hashlib.sha1(fic.read_bytes(), usedforsecurity=False).hexdigest()
    return ent


def learn_table(name: str, fic: Path, xml: Path) -> dict[str, Any]:
    """Learned layout, or an entry with the error (the table then falls back to WDMap)."""
    try:
        return Table(name, fic, xml).learn()
    except Exception as e:  # noqa: BLE001 - keep going; one bad table must not stop the others
        return {"table": name, "error": f"{type(e).__name__}: {e}", "columns": []}


def _summary(name: str, res: dict[str, Any]) -> str:
    return (
        f"{name}\trows={res.get('xml_rows')}\tcols={len(res.get('columns', []))}/{len(res.get('xml_columns', []))}"
        f"\tunmatched={len(res.get('unmatched', []))}\tfailed={len(res.get('failed_columns', []))}"
        f"\t{res.get('error', '')}\t{res.get('learn_seconds', '')}s"
    )


def learn_all(doc: dict[str, Any], want: list[str], fics: dict[str, Path], xmls: dict[str, Path], st) -> None:
    """Learn the wanted tables into doc["tables"]."""
    for name in want:
        if name not in fics:
            log(name, "no .fic")
            continue
        xml = xmls.get(name.lower())
        if not xml or st.get(name, "OK") != "OK":
            doc["tables"][name] = empty_entry(name, fics[name], st.get(name, "no xml"))
            continue
        res = learn_table(name, fics[name], xml)
        doc["tables"][name] = res
        log(_summary(name, res))


def refresh_null_bits(doc: dict[str, Any], want: list[str], fics: dict[str, Path], xmls: dict[str, Path]) -> None:
    """Recompute NULL bits of learned tables whose XML has missing elements."""
    for name in want:
        lay = doc["tables"].get(name)
        xml = xmls.get(name.lower())
        if not lay or not lay.get("columns") or not xml:
            continue
        ncols = len(lay["xml_columns"])
        if all(len(r) == ncols for r in rows_of(xml, name)):
            continue
        table = Table(name, fics[name], xml)
        got = table.update_null_bits()
        if got:
            table.null_bits(lay, *got)
            log(name, [(c["name"], c.get("null_bit")) for c in lay["columns"] if has_null_bit(c)])


def has_null_bit(col: dict[str, Any]) -> bool:
    """True if a layout column has a NULL bit (found or not)."""
    return "null_bit" in col or bool(col.get("null_bit_unknown"))


def write_doc(path: Path, doc: dict[str, Any]) -> None:
    """Write the layouts document."""
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Command-line options."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="folder with the .fic/.mmo files")
    ap.add_argument("--xml", required=True, help="folder with WDMap's XML export of the same files")
    ap.add_argument("--tables", default="", help="comma-separated tables (default: all)")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--merge", action="store_true", help="update only the given tables in an existing file")
    ap.add_argument("--update-null-bits", action="store_true",
                    help="only (re)compute NULL bitmap bits of tables whose XML has missing elements")  # fmt: skip
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    """CLI: learn layouts (or only refresh NULL bits) and write the layouts file."""
    a = parse_args(argv)
    out = Path(a.out)
    fics, xmls = fic_files(a.data), xml_files(a.xml)
    want = [t for t in a.tables.split(",") if t] or sorted(fics, key=str.lower)
    if a.update_null_bits:
        doc = json.loads(out.read_text(encoding="utf-8"))
        refresh_null_bits(doc, want, fics, xmls)
        write_doc(out, doc)
        return
    doc = json.loads(out.read_text(encoding="utf-8")) if a.merge and out.exists() else {"tables": {}}
    t0 = time.time()
    learn_all(doc, want, fics, xmls, export_statuses(a.xml))
    doc["learned_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    doc["source"] = {"data": a.data, "xml": a.xml}
    doc["layout_version"] = LAYOUT_VERSION
    out.resolve().parent.mkdir(parents=True, exist_ok=True)
    write_doc(out, doc)
    log(f"written {a.out} in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()

"""Learn the physical record layout of every gGest table from known plaintext.

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
import datetime
import json
import os
import random
import re
import struct
import sys
import time
from decimal import Decimal, InvalidOperation

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fic_reader import (FIXED, MemoFile, active_records, compile_decoder, decode, desc_hash,  # noqa: E402
                        frame_candidates)
from xmlrows import rows_of  # noqa: E402

LAYOUT_VERSION = 1
INT_TYPES = ["u8", "i16", "i32", "i64", "i8", "u16", "u32"]
DEC_TYPES = [f"cur{k}" for k in (7, 6, 4, 2, 3, 5, 8)] + \
            [f"dec{n}_{k}" for n in (6, 4, 2, 3, 5, 7) for k in (7, 6, 4, 2, 3, 5, 8)] + \
            [f"dec16_{k}" for k in (30, 20, 10, 8, 7, 6, 4, 2)]
FLOAT_TYPES = ["f64", "f64g", "f32"]
# preference when the data cannot tell encodings apart (lower = preferred)
PRIOR = {t: i for i, t in enumerate(
    ["str", "dt8", "date4", "memo", "i64", "i32", "u8", "i16", "cur7", "cur6", "f64", "dec6_6"] +
    INT_TYPES + DEC_TYPES + FLOAT_TYPES + ["time4"])}
NUMRE = re.compile(r"-?\d+(\.\d+)?$")
INTRE = re.compile(r"-?\d+$")
UUIDRE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
BITS = {"u8": 8, "i8": 7, "i16": 15, "u16": 16, "i32": 31, "u32": 32, "i64": 63}


def log(*a):
    print(*a, flush=True)


def size_hint(typ):
    return FIXED.get(typ, 0)


def type_options(values):
    """Encodings worth trying for a column, from its XML values."""
    vs = [v for v in values if v is not None]
    ne = [v for v in vs if v != ""]
    opts = ["str"]
    if ne and len(ne) == len(vs) and all(NUMRE.match(v) and canonical_number(v) for v in ne):
        if all(INTRE.match(v) for v in ne):
            mx = max(abs(int(v)) for v in ne)
            neg = any(v.startswith("-") for v in ne)
            for t in INT_TYPES:
                if t.startswith("u") and neg:
                    continue
                if mx < (1 << BITS[t]):
                    opts.append(t)
        opts += DEC_TYPES + FLOAT_TYPES
    if ne and all(len(v) == 8 and v.isdigit() for v in ne):
        opts.append("date4")
    if vs and all(len(v) == 17 and v.isdigit() for v in vs):
        opts.append("dt8")
    if ne and all(len(v) == 9 and v.isdigit() for v in ne):
        opts.append("time4")
    if ne and all(UUIDRE.match(v) for v in ne):
        opts.append("uuid16")
    opts.append("memo")
    return opts


def canonical_number(v):
    """True if v is written the way the reader formats numbers (no leading zeros, no trailing
    decimal zeros), so that a numeric encoding can reproduce it."""
    neg = v.startswith("-")
    w = v[1:] if neg else v
    ip, _, fp = w.partition(".")
    if len(ip) > 1 and ip.startswith("0"):
        return False
    if fp and fp.endswith("0"):
        return False
    if neg and w == "0":
        return False
    return True


def encode(v, typ):
    """Bytes an item of this type holds for XML value v (None if not representable / not exact)."""
    try:
        if typ == "str":
            return v.encode("cp1252") + b"\0"
        if typ in BITS:
            fmt = {"u8": "<B", "i8": "<b", "i16": "<h", "u16": "<H", "i32": "<i", "u32": "<I", "i64": "<q"}[typ]
            return struct.pack(fmt, int(v))
        if typ.startswith("cur") or typ.startswith("dec"):
            if typ.startswith("cur"):
                n, k = 8, int(typ[3:])
            else:
                n, k = (int(x) for x in typ[3:].split("_"))
            d = Decimal(v) * (Decimal(10) ** k)
            if d != d.to_integral_value():
                return None
            return int(d).to_bytes(n, "little", signed=True)
        if typ == "date4":
            if v == "":
                return bytes(4)
            return struct.pack("<BBH", int(v[6:8]), int(v[4:6]), int(v[:4]))
        if typ == "dt8":
            ms = int(v[8:10]) * 3600000 + int(v[10:12]) * 60000 + int(v[12:14]) * 1000 + int(v[14:17])
            return struct.pack("<BBHI", int(v[6:8]), int(v[4:6]), int(v[:4]), ms)
        if typ == "uuid16":
            return bytes(16) if v == "" else bytes.fromhex(v.replace("-", ""))
        if typ == "time4":
            ms = int(v[0:2]) * 3600000 + int(v[2:4]) * 60000 + int(v[4:6]) * 1000 + int(v[6:9])
            return struct.pack("<I", ms)
    except (ValueError, InvalidOperation, struct.error, OverflowError, UnicodeEncodeError):
        return None
    return None  # floats / memo: compared through decode()


class Table:
    def __init__(self, name, fic, xml):
        self.name = name
        self.fic = fic
        self.xml = xml
        with open(fic, "rb") as f:
            self.data = f.read()
        self.memo = MemoFile(os.path.splitext(fic)[0] + ".mmo")

    def memo_size(self):
        return self.memo.m.size if self.memo.m is not None else 0

    # ---------------------------------------------------------- 1. framing
    def frame(self, nrows):
        cands = frame_candidates(self.data)
        good = [c for c in cands if c["count"] == nrows]
        self.fr = good[0] if good else (cands[0] if cands else None)
        return self.fr

    # ---------------------------------------------------------- 2. alignment
    def align(self, recs, cols, vals):
        n = len(recs)
        sample = recs[:: max(1, n // 40)][:40]
        stride = self.fr["stride"]
        if n == 1:
            return [0], {"by": [], "single_row": True}
        uniq = [c for c in cols if None not in vals[c] and "" not in vals[c] and len(set(vals[c])) == n]
        uniq.sort(key=lambda c: -sum(len(v) for v in vals[c][:200]))
        for c in uniq[:12]:
            S = {v: i for i, v in enumerate(vals[c])}
            for typ in type_options(vals[c]):
                if typ in FLOAT_TYPES or typ in ("time4", "memo"):
                    continue
                sz = size_hint(typ)
                for o in range(7, stride - max(sz, 1) + 1):
                    ok = True
                    for r in sample:
                        v = decode(r, o, typ, 0)
                        if v is None or v not in S:
                            ok = False
                            break
                    if not ok:
                        continue
                    m = []
                    for r in recs:
                        v = decode(r, o, typ, 0)
                        if v not in S:
                            break
                        m.append(S[v])
                    if len(m) == n and len(set(m)) == n:
                        return m, {"by": [c], "offset": o, "type": typ}
        # composite key: columns whose decoded multiset equals the XML multiset
        found = []
        big = recs[:: max(1, n // 400)]
        for c in sorted(cols, key=lambda c: -len(set(vals[c]))):
            if found and len(set(zip(*[vals[f] for f, _ in found]))) == n:
                break
            if len(set(vals[c])) < 2 or None in vals[c]:
                continue
            S = set(vals[c])
            target = collections.Counter(vals[c])
            hit = None
            for typ in type_options(vals[c]):
                if typ in FLOAT_TYPES or typ in ("time4", "memo"):
                    continue
                for o in range(7, stride - max(size_hint(typ), 1) + 1):
                    dec = [decode(r, o, typ, 0) for r in sample]
                    if all(d in S for d in dec) and len(set(dec)) > 1 and                             all(decode(r, o, typ, 0) in S for r in big):
                        full = [decode(r, o, typ, 0) for r in recs]
                        if collections.Counter(full) == target:
                            hit = (o, typ, full)
                            break
                if hit:
                    break
            if hit:
                found.append((c, hit))
            if len(found) >= 10:
                break
        if not found:
            return None, None
        rk = [tuple(h[2][i] for _, h in found) for i in range(n)]
        xk = [tuple(vals[c][j] for c, _ in found) for j in range(n)]
        if collections.Counter(rk) != collections.Counter(xk):
            return None, None
        pool = collections.defaultdict(list)
        for j, k in enumerate(xk):
            pool[k].append(j)
        m = [pool[k].pop(0) for k in rk]
        cnt = collections.Counter(xk)
        amb = [i for i in range(n) if cnt[rk[i]] > 1]
        return m, {"by": [c for c, _ in found], "composite": True, "unique_rows": n - len(amb),
                   "ambiguous_rows": amb}

    # ---------------------------------------------------------- 3. layout
    def learn(self):
        t0 = time.time()
        rows = list(rows_of(self.xml, self.name))
        cols = xml_column_order(rows)
        dicts = [dict(r) for r in rows]
        vals = {c: [d.get(c) for d in dicts] for c in cols}
        out = {"table": self.name, "layout_version": LAYOUT_VERSION, "xml_rows": len(rows), "xml_columns": cols}
        fr = self.frame(len(rows))
        if not fr:
            out["error"] = "no framing"
            return out
        out.update({"stride": fr["stride"], "rec0": fr["rec0"], "desc_sha1": desc_hash(self.data, fr["rec0"]),
                    "slots": fr["slots"], "active": fr["count"]})
        if fr["count"] != len(rows):
            out["error"] = f"active records {fr['count']} != XML rows {len(rows)}"
            return out
        recs = [r for _, r in active_records(self.data, fr)]
        m, how = self.align(recs, cols, vals)
        if m is None:
            out["error"] = "alignment failed"
            return out
        out["alignment"] = {k: v for k, v in how.items() if k != "ambiguous_rows"}
        amb = set(how.get("ambiguous_rows", []))
        X = {c: [vals[c][m[i]] for i in range(len(recs))] for c in cols}
        use = [i for i in range(len(recs)) if i not in amb]
        if not use:
            out["error"] = "no unambiguous rows"
            return out
        out.update(self.place(recs, cols, X, use))
        self.null_bits(out, recs, X)
        out["learn_seconds"] = round(time.time() - t0, 1)
        return out

    def null_bits(self, out, recs, X):
        """WDMap omits the element of a NULL item. NULL is a cleared bit in the bitmap that starts at
        record offset 8 (LSB first). For every column that is NULL in some rows, find the bit whose
        cleared state matches exactly the rows where the element is missing."""
        n = len(recs)
        nbits = 8 * min(64, max(1, self.fr["stride"] - 8))
        for col in out.get("columns", []):
            miss = [X[col["name"]][i] is None for i in range(n)]
            if not any(miss):
                continue
            for bit in range(nbits):
                o, m = 8 + bit // 8, 1 << (bit % 8)
                if all((not (r[o] & m)) == x for r, x in zip(recs, miss)):
                    col["null_bit"] = bit
                    break
            else:
                col["null_bit_unknown"] = True

    def update_null_bits(self):
        """Recompute null bits for an already learned layout (no re-learning of offsets)."""
        rows = list(rows_of(self.xml, self.name))
        cols = []
        for r in rows:
            for c, _ in r:
                if c not in cols:
                    cols.append(c)
        dicts = [dict(r) for r in rows]
        vals = {c: [d.get(c) for d in dicts] for c in cols}
        self.frame(len(rows))
        recs = [r for _, r in active_records(self.data, self.fr)]
        m, _ = self.align(recs, cols, vals)
        if m is None:
            return None
        return recs, {c: [vals[c][m[i]] for i in range(len(recs))] for c in cols}

    def candidates(self, c, opts, X, sample, srecs, stride, constant=False):
        """{pos: [types]} where the type reproduces the XML value of column c in every sampled row."""
        pairs = [(r, X[c][i]) for r, i in zip(srecs, sample) if X[c][i] is not None]
        if not pairs:
            return {}
        pr, pv = max(pairs, key=lambda rv: (rv[1] not in ("", "0"), len(rv[1])))
        out = collections.defaultdict(list)
        for t in opts:
            sz = size_hint(t)
            fuzzy = t == "str" and any("�" in v for _, v in pairs)
            if fuzzy:
                e = None       # undefined cp1252 bytes in the XML: compare decoded text, not bytes
            elif t == "str":
                e = pv.encode("cp1252", "replace") + b"\0"
            elif t in ("f64", "f32"):
                try:
                    e = struct.pack("<d", float(pv)) if t == "f64" else None
                except (ValueError, OverflowError):
                    continue
            elif t in ("f64g", "memo"):
                e = None
            else:
                e = encode(pv, t)
                if e is None:
                    continue
            if e is not None:
                poss, i = [], pr.find(e)
                while i >= 0:
                    poss.append(i)
                    i = pr.find(e, i + 1)
            else:
                poss = range(8, stride - max(sz, 1) + 1)
            if fuzzy:
                encs = [None] * len(pairs)
            elif t == "str":
                encs = [v.encode("cp1252", "replace") for _, v in pairs]
            elif t in FLOAT_TYPES or t == "memo":
                encs = [None] * len(pairs)
            else:
                encs = [encode(v, t) for _, v in pairs]
                if any(x is None for x in encs):
                    continue
            const = constant
            for pos in poss:
                if pos < 8 or pos + max(sz, 1) > stride:
                    continue
                if const and t != "memo":
                    # same value in every sampled row: the probe row decides, and the bytes must
                    # not vary across the sample (memo pointers differ even for equal texts)
                    w = len(pairs[0][1]) + 1 if t == "str" else sz
                    if not all(self._constb[pos:pos + w]):
                        continue
                    check = pairs[:1]
                else:
                    check = pairs
                ok = True
                for (r, v), ev in zip(check, encs):
                    if fuzzy:
                        if decode(r, pos, "str", 0) != v:
                            ok = False
                            break
                    elif t == "str":
                        if not r.startswith(ev, pos) or (pos + len(ev) < stride and r[pos + len(ev)] != 0):
                            ok = False
                            break
                    elif ev is None:
                        if t == "memo" and v == "" and r[pos:pos + 8] not in (bytes(8), b"\xff" * 8):
                            ok = False
                            break
                        if decode(r, pos, t, sz, self.memo) != v:
                            ok = False
                            break
                    elif r[pos:pos + sz] != ev:
                        ok = False
                        break
                if ok:
                    out[pos].append(t)
        return dict(out)

    def place(self, recs, cols, X, use):
        stride = self.fr["stride"]
        rnd = random.Random(1)
        sample = sorted(set(use[:5] + use[-5:] + rnd.sample(use, min(len(use), 60))))
        srecs = [recs[i] for i in sample]
        opts, minw, varies, special, maxabs = {}, {}, {}, {}, {}
        for c in cols:
            vs = [X[c][i] for i in use]
            opts[c] = type_options(vs)
            minw[c] = max((len(v.encode("cp1252", "replace")) for v in vs if v is not None), default=0) + 1
            varies[c] = len(set(vs)) > 1
            if not varies[c] and vs:
                # a constant value cannot tell same-size encodings apart: keep the preferred one per size
                v0, keep = vs[0], {}
                for t in sorted(opts[c], key=lambda t: PRIOR.get(t, 99)):
                    if t in ("str", "memo", "dt8", "date4", "uuid16", "time4"):
                        keep[t] = t
                    elif t in FLOAT_TYPES:
                        keep.setdefault((t, size_hint(t)), t)
                    elif v0 is not None and encode(v0, t) is not None:
                        # same size and same bytes = indistinguishable; keep the preferred one
                        keep.setdefault((size_hint(t), encode(v0, t)), t)
                opts[c] = list(keep.values())
            if "i64" in opts[c] or "u8" in opts[c] or "i32" in opts[c]:
                maxabs[c] = max(abs(int(v)) for v in vs if v)
            # rows carrying distinct values of this column (rare values matter most)
            seen = {}
            if varies[c]:
                for i in use:
                    v = X[c][i]
                    if v not in seen:
                        seen[v] = i
                        if len(seen) >= 16:
                            break
            special[c] = sorted(set(sample) | set(seen.values()))
        self._constb = [len(set(r[p] for r in srecs)) == 1 for p in range(stride)]
        self._varies = varies
        cands = {}
        for c in cols:
            rows_c = special[c]
            cands[c] = self.candidates(c, opts[c], X, rows_c, [recs[i] for i in rows_c], stride,
                                       constant=not varies[c])
        for c in cols:
            if not varies[c]:
                for pos, ts in cands[c].items():
                    best = {}
                    for t in sorted(ts, key=lambda t: PRIOR.get(t, 99)):
                        best.setdefault(minw[c] if t == "str" else size_hint(t), t)
                    cands[c][pos] = list(best.values())
        banned = set()
        result = None
        for attempt in range(6):
            placed = self._assign(cols, cands, minw, varies, banned, stride, maxabs)
            columns = self._finish(cols, placed, minw, stride)
            bad = self._verify(columns, recs, X, use)
            if not bad:
                result = columns
                break
            for col in bad:
                banned.add((col["name"], col["offset"], col["type"]))
            result = columns
        failed = []
        for col in result:
            col["constant_in_data"] = not varies[col["name"]]
        bad = self._verify(result, recs, X, use, record=True)
        failed = [c["name"] for c in bad]
        names = {c["name"] for c in result}
        unmatched = [c for c in cols if c not in names]
        return {"columns": result, "unmatched": unmatched, "failed_columns": failed,
                "validated_rows": len(use)}

    def _assign(self, cols, cands, minw, varies, banned, stride, maxabs=None):
        maxabs = maxabs or {}
        occ = bytearray(stride)
        occ[0:8] = b"\1" * 8
        placed = {}   # c -> (pos, [types])
        idx = {c: i for i, c in enumerate(cols)}

        def smin(c, t):
            return minw[c] if t == "str" else size_hint(t)

        # per column: {pos: [(size, type), ...] sorted by size}
        bysize = {}
        for c, cc in cands.items():
            d = {}
            for pos, ts in cc.items():
                lst = sorted((smin(c, t), PRIOR.get(t, 99), t) for t in ts)
                d[pos] = [(sz, t) for sz, _, t in lst]
            bysize[c] = d

        def options(c):
            res = []
            for pos, lst in bysize.get(c, {}).items():
                ok = []
                for sz, t in lst:
                    if pos + sz > stride or any(occ[pos:pos + sz]):
                        break          # larger sizes overlap too
                    if (c, pos, t) not in banned:
                        ok.append(t)
                if ok:
                    res.append((pos, ok))
            return res

        def put(c, pos, ts):
            placed[c] = (pos, ts)
            s = min(smin(c, t) for t in ts)
            occ[pos:pos + s] = b"\1" * s

        def neighbour_choice(c, o):
            i = idx[c]
            prev = next((cols[j] for j in range(i - 1, -1, -1) if cols[j] in placed), None)
            nxt = next((cols[j] for j in range(i + 1, len(cols)) if cols[j] in placed), None)
            if prev is not None:
                pp, pts = placed[prev]
                ends = {pp + smin(prev, t) for t in pts}
                for pos, ts in o:
                    if pos in ends:
                        return pos, ts
            if nxt is not None:
                npos = placed[nxt][0]
                for pos, ts in o:
                    fit = [t for t in ts if pos + smin(c, t) == npos]
                    if fit:
                        return pos, fit
            # otherwise the option that explains the most bytes (e.g. an 8-digit string beats a
            # 4-byte date that only matches the date part of a datetime), then the lowest offset
            return max(o, key=lambda x: (max(smin(c, t) for t in x[1]), -x[0]))

        # 1. columns whose values vary: constraint propagation, then most-constrained first
        remaining = [c for c in cols if cands.get(c) and (varies[c] or len(cands[c]) <= 3)]
        while remaining:
            progress = False
            opts_now = {}
            for c in list(remaining):
                o = options(c)
                if not o:
                    remaining.remove(c)
                    progress = True
                elif len(o) == 1:
                    put(c, *o[0])
                    remaining.remove(c)
                    progress = True
                else:
                    opts_now[c] = o
            if progress:
                continue
            c = min(remaining, key=lambda c: (len(opts_now[c]), idx[c]))
            put(c, *neighbour_choice(c, sorted(opts_now[c])))
            remaining.remove(c)
        # 1b. give each varying fixed-size column its most plausible width before constants are
        #     placed: exact fit up to the next item, else 8-byte decimals, else ints by magnitude
        starts = sorted(p for p, _ in placed.values())
        for c, (pos, ts) in list(placed.items()):
            fixed = [t for t in ts if t != "str"]
            if not fixed or "str" in ts:
                continue
            nxt = next((x for x in starts if x > pos), stride)
            room = nxt - pos
            # an exact fit is trusted only when the next item is this column's XML successor
            # (otherwise the gap may hold columns that are constant in the data)
            succ = cols[idx[c] + 1] if idx[c] + 1 < len(cols) else None
            trust = succ is not None and succ in placed and placed[succ][0] == nxt
            pick = [t for t in fixed if size_hint(t) == room] if trust else []
            if not pick:
                fitting = [t for t in fixed if size_hint(t) <= room]
                decs = [t for t in fitting if t.startswith("cur") or t.startswith("dec")]
                ints = [t for t in fitting if t in BITS]
                if decs and not ints:
                    pick = [t for t in decs if size_hint(t) == 8] or sorted(decs, key=lambda t: -size_hint(t))
                elif ints:
                    mx = maxabs.get(c, 0)
                    want = 1 if mx < 128 else 2 if mx < 32768 else 4 if mx < (1 << 31) else 8
                    pick = sorted(ints, key=lambda t: (abs(size_hint(t) - want), PRIOR.get(t, 99)))[:1]
                else:
                    pick = fitting or fixed
            pick = sorted(pick, key=lambda t: PRIOR.get(t, 99))[:1]
            placed[c] = (pos, pick)
            sz = size_hint(pick[0])
            occ[pos:pos + sz] = b"\x01" * sz
        # 2. constant columns (position not identifiable from values): XML order, next to neighbours
        for c in sorted(cols, key=lambda c: (len(cands.get(c) or ()) > 3, idx[c])):
            if c in placed or not cands.get(c):
                continue
            o = options(c)
            if o:
                put(c, *neighbour_choice(c, sorted(o)))
        return placed

    def _finish(self, cols, placed, minw, stride):
        starts = sorted(pos for pos, _ in placed.values())
        columns = []
        for c in cols:
            if c not in placed:
                continue
            pos, ts = placed[c]
            nxt = next((s for s in starts if s > pos), stride)
            room = nxt - pos
            if "str" in ts and len(ts) == 1:
                columns.append({"name": c, "offset": pos, "size": max(room, minw[c]), "type": "str"})
                continue
            fixed = [t for t in ts if t != "str"]
            # largest encoding that fits the room up to the next item; prior breaks ties
            exact = [t for t in fixed if size_hint(t) == room] if self._varies.get(c, True) else []
            fit = exact or [t for t in fixed if size_hint(t) <= room] or fixed
            t = sorted(fit, key=lambda t: PRIOR.get(t, 99))[0]
            if "str" in ts and not fixed:
                t = "str"
            columns.append({"name": c, "offset": pos, "size": size_hint(t), "type": t})
        return columns

    def _verify(self, columns, recs, X, use, record=False):
        cache = self.__dict__.setdefault("_vcache", {})
        bad = []
        for col in columns:
            c, o, t, sz = col["name"], col["offset"], col["type"], col["size"]
            key = (c, o, t, sz)
            if not record and key in cache:
                if not cache[key]:
                    bad.append(col)
                continue
            f = compile_decoder(t, o, sz, self.memo)
            xc = X[c]
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
                    if not record:
                        break
            cache[key] = not mism
            if mism:
                if record:
                    col["mismatches"] = mism
                    col["example"] = ex
                bad.append(col)
        return bad


def xml_column_order(rows):
    """Column order of the export: a NULL item's element is omitted, so take the order of the
    longest row and add columns never seen there in first-seen order."""
    cols = [c for c, _ in max(rows, key=len)] if rows else []
    for r in rows:
        for c, _ in r:
            if c not in cols:
                cols.append(c)
    return cols


def statuses(xml_dir):
    st = {}
    for lp in sorted(os.listdir(xml_dir)):
        if lp.startswith("_log_worker") and lp.endswith(".tsv"):
            for line in open(os.path.join(xml_dir, lp), encoding="utf-8", errors="replace"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    name = parts[0].lstrip("\ufeff")
                    if st.get(name) != "OK":
                        st[name] = parts[2]
    return st


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="folder with the .fic/.mmo files")
    ap.add_argument("--xml", required=True, help="folder with WDMap's XML export of the same files")
    ap.add_argument("--tables", default="", help="comma-separated tables (default: all)")
    ap.add_argument("--out", default=os.path.join(HERE, "layouts", "ggest_layouts.json"))
    ap.add_argument("--merge", action="store_true", help="update only the given tables in an existing file")
    ap.add_argument("--update-null-bits", action="store_true",
                    help="only (re)compute NULL bitmap bits of tables whose XML has missing elements")
    a = ap.parse_args()
    fics = {os.path.splitext(f)[0]: os.path.join(a.data, f) for f in os.listdir(a.data)
            if f.lower().endswith(".fic")}
    xmls = {os.path.splitext(f)[0].lower(): os.path.join(a.xml, f) for f in os.listdir(a.xml)
            if f.lower().endswith(".xml")}
    st = statuses(a.xml)
    want = [t for t in a.tables.split(",") if t] or sorted(fics, key=str.lower)
    doc = {"tables": {}}
    if a.merge and os.path.exists(a.out):
        with open(a.out, encoding="utf-8") as f:
            doc = json.load(f)
    t0 = time.time()
    if a.update_null_bits:
        with open(a.out, encoding="utf-8") as f:
            doc = json.load(f)
        for name in want:
            lay = doc["tables"].get(name)
            xml = xmls.get(name.lower())
            if not lay or not lay.get("columns") or not xml:
                continue
            cols = lay["xml_columns"]
            if all(len(r) == len(cols) for r in rows_of(xml, name)):
                continue
            T = Table(name, fics[name], xml)
            got = T.update_null_bits()
            if got:
                T.null_bits(lay, *got)
                log(name, [(c["name"], c.get("null_bit")) for c in lay["columns"] if "null_bit" in c or
                           c.get("null_bit_unknown")])
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        return
    for name in want:
        if name not in fics:
            log(name, "no .fic")
            continue
        xml = xmls.get(name.lower())
        if not xml or st.get(name, "OK") != "OK":
            ent = {"table": name, "xml_rows": 0, "status": st.get(name, "no xml"), "columns": []}
            if st.get(name) == "EMPTY_OR_NO_EXPORT":
                # an empty table is read natively as empty only while its .fic stays byte-identical
                import hashlib
                with open(fics[name], "rb") as f:
                    ent["empty_sha1"] = hashlib.sha1(f.read()).hexdigest()
            doc["tables"][name] = ent
            continue
        try:
            res = Table(name, fics[name], xml).learn()
        except Exception as e:  # keep going; the table falls back to WDMap
            res = {"table": name, "error": f"{type(e).__name__}: {e}", "columns": []}
        doc["tables"][name] = res
        log(f"{name}\trows={res.get('xml_rows')}\tcols={len(res.get('columns', []))}/{len(res.get('xml_columns', []))}"
            f"\tunmatched={len(res.get('unmatched', []))}\tfailed={len(res.get('failed_columns', []))}"
            f"\t{res.get('error', '')}\t{res.get('learn_seconds', '')}s")
    doc["learned_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    doc["source"] = {"data": a.data, "xml": a.xml}
    doc["layout_version"] = LAYOUT_VERSION
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    log(f"written {a.out} in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()

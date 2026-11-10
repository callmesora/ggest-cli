"""Reader for HFSQL Classic memo files (.mmo), written from observed file layout.

Block layout (little-endian), starting at a block offset B:
  B+0   u16   block tag / checksum (varies)
  B+2   u32   payload size in this block
  B+6   u32   payload size (repeated)
  B+10  u8    flag (0 = last block of the memo)
  B+11  u64   offset of the next block (all 0xFF = none)
  B+19  u16   unknown
  B+21  payload bytes
A memo's content = concatenation of payloads along the chain.

Content layout (first 4 bytes = memo kind):
  kind 1 (text):   u32 kind, u8 ?, 10 bytes, u32 len, <len bytes text (cp1252)>
  kind 3 (binary): u32 kind, u8 ?, u32 unix time, u16 len1, u16 len2,
                   <len1 bytes original full path, NUL>, <len2 bytes short path, NUL>,
                   <binary data with a small WinDev image/blob wrapper>

Usage: py hfsql_mmo.py <file.mmo>...   (summary of the memo kinds in each file)
"""

import struct
import sys
from collections import Counter
from pathlib import Path
from typing import Any

HDR = 21
FIRST_BLOCK = 0xD2
NO_NEXT = 0xFFFFFFFFFFFFFFFF
TYPE_TEXT, TYPE_BINARY, TYPE_NAMED = 0x0C, 0x0D, 0x00
HEAD_ROLES = (0xF4, 0xE4)  # single-block memo, first block of a chain
BLOCK_CLASSES = range(4, 32)
WRAPPER = 27  # 0x01 + WinDev image/blob wrapper in front of the data
SIGS = [(b"\x89PNG\r\n\x1a\n", "png"), (b"\xff\xd8\xff", "jpg"), (b"GIF8", "gif"),
        (b"%PDF", "pdf"), (b"PK\x03\x04", "zip"), (b"BM", "bmp"), (b"II*\x00", "tif"),
        (b"\xd0\xcf\x11\xe0", "ole")]  # fmt: skip

Memo = dict[str, Any]


class Mmo:
    """An open .mmo file (kept open for the lifetime of the object; read-only)."""

    def __init__(self, path: str | Path) -> None:
        self.f = Path(path).open("rb")  # noqa: SIM115 - random access for the object's lifetime
        self.size = Path(path).stat().st_size

    def block(self, off: int) -> dict[str, int]:
        """Header of the block at off."""
        self.f.seek(off)
        h = self.f.read(HDR)
        if len(h) < HDR:
            raise ValueError(f"short block header at {off:#x}")
        tag, s1, s2, flag, nxt, _ = struct.unpack("<HIIBQH", h)
        return {"off": off, "tag": tag, "size": s1, "size2": s2, "flag": flag, "next": nxt}

    def raw(self, off: int, limit: int = 1 << 30) -> bytes:
        """Concatenated payload of the memo whose first block is at `off`."""
        out, seen = bytearray(), set()
        while off != NO_NEXT and off not in seen:
            seen.add(off)
            b = self.block(off)
            if b["size"] != b["size2"] or off + HDR + b["size"] > self.size:
                raise ValueError(f"bad block at {off:#x}: {b}")
            self.f.seek(off + HDR)
            out += self.f.read(b["size"])
            if len(out) > limit:
                break
            off = b["next"]
        return bytes(out)


def sniff(blob: bytes, window: int = 64) -> tuple[str, int | None]:
    """(file extension, offset of its signature) of a binary memo; ("bin", None) when unknown."""
    for sig, e in SIGS:
        i = blob.find(sig, 0, window)
        if i >= 0:
            return e, i
    return "bin", None


def decode_text(raw: bytes) -> tuple[str, str]:
    """(text, encoding). Unicode memos are UTF-16LE: many NULs on odd positions."""
    if len(raw) >= 4 and raw[1::2].count(0) > len(raw) * 0.4:  # noqa: PLR2004 - heuristic threshold
        return raw.decode("utf-16-le", "replace"), "utf-16-le"
    return raw.decode("cp1252", "replace"), "cp1252"


def _parse_inline(content: bytes, item: int, typ: int) -> Memo:
    rec, _, flags, n = struct.unpack_from("<IIHI", content, 5)
    raw = content[19 : 19 + n]
    if typ == TYPE_TEXT:
        text, enc = decode_text(raw)
        return {"kind": "text", "item": item, "rec": rec, "flags": flags, "text": text, "enc": enc}
    ext, start = sniff(raw)
    return {"kind": "binary", "item": item, "rec": rec, "flags": flags, "ext": ext,
            "data": raw[start or 0 :], "names": ("", "")}  # fmt: skip


def _cstr(content: bytes, p: int, n: int) -> tuple[str, int]:
    """Text of n bytes at p and the offset after it (and after its NUL, if any)."""
    return content[p : p + n].decode("cp1252", "replace"), p + n + (1 if n else 0)


def _parse_named(content: bytes, item: int) -> Memo:
    ts, l1, l2 = struct.unpack_from("<IHH", content, 5)
    full, p = _cstr(content, 13, l1)
    short, p = _cstr(content, p, l2)
    blob = content[p:]
    ext, start = sniff(blob)
    if start is None and len(blob) >= WRAPPER and blob[0] == 1:
        # 0x01, u32 size, u32 crc, u32, u32, u16 0x8001, u32 data len, u16 w, u16 h, data
        dlen = struct.unpack_from("<I", blob, 19)[0]
        data = blob[WRAPPER : WRAPPER + dlen]
    else:
        data = blob[start or 0 :]
    return {"kind": "binary", "item": item, "rec": None, "time": ts, "ext": ext,
            "data": data, "names": (full, short)}  # fmt: skip


def parse(content: bytes) -> Memo:
    """Decode one memo's content.

    Common header: u32 item index, u8 type.
      type 0x0c (text) / 0x0d (binary): u32 record number, 4 bytes, u16 flags, u32 len, data.
      type 0x00 (binary with file names): u32 unix time, u16 len1, u16 len2,
           name1 [+NUL], name2 [+NUL], then 0x01 + wrapper + data.
    """
    item, typ = struct.unpack_from("<IB", content, 0)
    if typ in (TYPE_TEXT, TYPE_BINARY):
        return _parse_inline(content, item, typ)
    if typ == TYPE_NAMED:
        return _parse_named(content, item)
    return {"kind": f"unknown{typ:#x}", "item": item, "data": content}


def first_blocks(m: Mmo) -> list[int]:
    """Offsets of every memo's first block.

    Tag low byte = log2(block allocation); tag high byte = block role:
      0xF4 single-block memo, 0xE4 first block of a chain, 0xC4 middle, 0xD4 last, 0x00 free.
    """
    off, heads = FIRST_BLOCK, []
    while off + HDR <= m.size:
        b = m.block(off)
        cls, role = b["tag"] & 0xFF, b["tag"] >> 8
        if cls not in BLOCK_CLASSES:
            raise ValueError(f"walk broke at {off:#x}: {b}")
        if role in HEAD_ROLES and b["size"]:
            heads.append(off)
        off += 1 << cls
    if off != m.size:
        raise ValueError(f"walk ended at {off:#x}, file size {m.size:#x}")
    return heads


def summary(path: str | Path) -> str:
    """One line: file name, size, number of memos and count per kind (or the walk error)."""
    m = Mmo(path)
    try:
        heads = first_blocks(m)
    except ValueError as e:
        return f"{Path(path).name} WALK ERROR {e}"
    kinds: Counter[str] = Counter()
    for h in heads:
        try:
            r = parse(m.raw(h))
            k = r["kind"] + ("/" + r["ext"] if "ext" in r else "")
        except (ValueError, struct.error) as e:
            k = "ERR " + type(e).__name__
        kinds[k] += 1
    return f"{Path(path).name} {m.size} memos: {len(heads)} {dict(kinds)}"


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        print(summary(arg))

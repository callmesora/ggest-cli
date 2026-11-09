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
"""
import struct, sys, os

HDR = 21
FIRST_BLOCK = 0xD2
NO_NEXT = 0xFFFFFFFFFFFFFFFF
SIGS = [(b"\x89PNG\r\n\x1a\n", "png"), (b"\xff\xd8\xff", "jpg"), (b"GIF8", "gif"),
        (b"%PDF", "pdf"), (b"PK\x03\x04", "zip"), (b"BM", "bmp"), (b"II*\x00", "tif"),
        (b"\xd0\xcf\x11\xe0", "ole")]


class Mmo:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.size = os.fstat(self.f.fileno()).st_size

    def block(self, off):
        self.f.seek(off)
        h = self.f.read(HDR)
        if len(h) < HDR:
            raise ValueError(f"short block header at {off:#x}")
        tag, s1, s2, flag, nxt, unk = struct.unpack("<HIIBQH", h)
        return {"off": off, "tag": tag, "size": s1, "size2": s2, "flag": flag, "next": nxt}

    def raw(self, off, limit=1 << 30):
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


def sniff(blob, window=64):
    for sig, e in SIGS:
        i = blob.find(sig, 0, window)
        if i >= 0:
            return e, i
    return "bin", None


def decode_text(raw):
    # Unicode memos are UTF-16LE: many NULs on odd positions.
    if len(raw) >= 4 and raw[1::2].count(0) > len(raw) * 0.4:
        return raw.decode("utf-16-le", "replace"), "utf-16-le"
    return raw.decode("cp1252", "replace"), "cp1252"


def parse(content):
    """Decode one memo's content.

    Common header: u32 item index, u8 type.
      type 0x0c (text) / 0x0d (binary): u32 record number, 4 bytes, u16 flags, u32 len, data.
      type 0x00 (binary with file names): u32 unix time, u16 len1, u16 len2,
           name1 [+NUL], name2 [+NUL], then 0x01 + wrapper + data.
    """
    item, typ = struct.unpack_from("<IB", content, 0)
    if typ in (0x0C, 0x0D):
        rec, _, flags, n = struct.unpack_from("<IIHI", content, 5)
        raw = content[19:19 + n]
        if typ == 0x0C:
            text, enc = decode_text(raw)
            return {"kind": "text", "item": item, "rec": rec, "flags": flags, "text": text, "enc": enc}
        ext, start = sniff(raw)
        return {"kind": "binary", "item": item, "rec": rec, "flags": flags, "ext": ext,
                "data": raw[start or 0:], "names": ("", "")}
    if typ == 0x00:
        ts, l1, l2 = struct.unpack_from("<IHH", content, 5)
        p = 13
        full = content[p:p + l1].decode("cp1252", "replace")
        p += l1 + (1 if l1 else 0)
        short = content[p:p + l2].decode("cp1252", "replace")
        p += l2 + (1 if l2 else 0)
        blob = content[p:]
        ext, start = sniff(blob)
        if start is None and len(blob) >= 27 and blob[0] == 1:
            # 0x01, u32 size, u32 crc, u32, u32, u16 0x8001, u32 data len, u16 w, u16 h, data
            dlen = struct.unpack_from("<I", blob, 19)[0]
            data = blob[27:27 + dlen]
        else:
            data = blob[start or 0:]
        return {"kind": "binary", "item": item, "rec": None, "time": ts, "ext": ext,
                "data": data, "names": (full, short)}
    return {"kind": f"unknown{typ:#x}", "item": item, "data": content}


def read_memo(mmo_path, ref):
    """ref = file offset of the memo's first block."""
    m = Mmo(mmo_path)
    return parse(m.raw(ref))


def first_blocks(m):
    """Offsets of every memo's first block.

    Tag low byte = log2(block allocation); tag high byte = block role:
      0xF4 single-block memo, 0xE4 first block of a chain, 0xC4 middle, 0xD4 last, 0x00 free.
    """
    off, heads = FIRST_BLOCK, []
    while off + HDR <= m.size:
        b = m.block(off)
        cls, role = b["tag"] & 0xFF, b["tag"] >> 8
        if not 4 <= cls <= 31:
            raise ValueError(f"walk broke at {off:#x}: {b}")
        if role in (0xF4, 0xE4) and b["size"]:
            heads.append(off)
        off += 1 << cls
    if off != m.size:
        raise ValueError(f"walk ended at {off:#x}, file size {m.size:#x}")
    return heads


if __name__ == "__main__":
    for path in sys.argv[1:]:
        m = Mmo(path)
        try:
            heads = first_blocks(m)
        except ValueError as e:
            print(os.path.basename(path), "WALK ERROR", e)
            continue
        kinds = {}
        for h in heads:
            try:
                r = parse(m.raw(h))
                k = r["kind"] + ("/" + r["ext"] if "ext" in r else "")
            except Exception as e:
                k = "ERR " + type(e).__name__
            kinds[k] = kinds.get(k, 0) + 1
        print(os.path.basename(path), m.size, "memos:", len(heads), kinds)

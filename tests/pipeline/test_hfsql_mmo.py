import struct

import hfsql_mmo as mm
import pytest
from pipeline_fakes import binary_memo, make_mmo, named_memo, text_memo

PNG = b"\x89PNG\r\n\x1a\n" + b"pixels"


def _write(tmp_path, memos, split=0):
    raw, heads = make_mmo(memos, split)
    path = tmp_path / "t.mmo"
    path.write_bytes(raw)
    return path, heads


def test_text_and_chained_memos(tmp_path):
    long_text = "line of text " * 10
    path, heads = _write(tmp_path, [text_memo(3, 9, "short"), text_memo(4, 10, long_text)], split=40)
    m = mm.Mmo(path)
    assert mm.first_blocks(m) == heads
    first = mm.parse(m.raw(heads[0]))
    assert first == {"kind": "text", "item": 3, "rec": 9, "flags": 0, "text": "short", "enc": "cp1252"}
    assert mm.parse(m.raw(heads[1]))["text"] == long_text
    assert len(m.raw(heads[1], limit=10)) == 40  # stops after the block that passes the limit


def test_utf16_text_is_detected():
    raw = "accented".encode("utf-16-le")
    assert mm.decode_text(raw) == ("accented", "utf-16-le")
    assert mm.decode_text(b"ab") == ("ab", "cp1252")


def test_binary_memos():
    inline = mm.parse(binary_memo(2, 5, b"xx" + PNG))
    assert (inline["kind"], inline["ext"], inline["data"], inline["rec"]) == ("binary", "png", PNG, 5)
    unknown = mm.parse(binary_memo(2, 5, b"\x00\x01"))
    assert (unknown["ext"], unknown["data"]) == ("bin", b"\x00\x01")


def test_named_binary_memo_with_wrapper():
    payload = b"rawdata!"
    wrapper = b"\x01" + bytes(18) + struct.pack("<I", len(payload)) + bytes(4) + payload
    r = mm.parse(named_memo(6, "C:\\docs\\a.dat", "a.dat", wrapper))
    assert r["names"] == ("C:\\docs\\a.dat", "a.dat")
    assert r["data"] == payload
    assert r["rec"] is None
    plain = mm.parse(named_memo(6, "", "", PNG))
    assert (plain["ext"], plain["data"], plain["names"]) == ("png", PNG, ("", ""))


def test_unknown_memo_type():
    assert mm.parse(b"\x01\x00\x00\x00\x07rest")["kind"] == "unknown0x7"


def test_bad_blocks(tmp_path):
    path, heads = _write(tmp_path, [text_memo(1, 1, "x")])
    m = mm.Mmo(path)
    with pytest.raises(ValueError, match="bad block"):
        m.raw(heads[0] + 1)
    with pytest.raises(ValueError, match="short block header"):
        m.block(m.size - 3)


def test_walk_errors(tmp_path):
    path = tmp_path / "broken.mmo"
    path.write_bytes(bytes(mm.FIRST_BLOCK) + bytes(30))  # tag 0: not a block class
    with pytest.raises(ValueError, match="walk broke"):
        mm.first_blocks(mm.Mmo(path))
    raw, _ = make_mmo([text_memo(1, 1, "x")])
    path.write_bytes(raw[:-1])
    with pytest.raises(ValueError, match="walk ended"):
        mm.first_blocks(mm.Mmo(path))


def test_summary(tmp_path):
    path, _ = _write(tmp_path, [text_memo(1, 1, "x"), binary_memo(2, 1, PNG), b"\x01\x00\x00\x00\x0c"])
    assert mm.summary(path) == f"t.mmo {path.stat().st_size} memos: 3 {{'text': 1, 'binary/png': 1, 'ERR error': 1}}"
    broken = tmp_path / "b.mmo"
    broken.write_bytes(bytes(mm.FIRST_BLOCK) + bytes(30))
    assert mm.summary(broken).startswith("b.mmo WALK ERROR walk broke")

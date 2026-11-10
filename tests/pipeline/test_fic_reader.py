import json
import struct
from decimal import Decimal

import fic_reader as fr
import pytest
import xmlrows
from pipeline_fakes import DESC, STRIDE, SampleTable, make_fic, make_mmo, make_record, rec0_of, text_memo


# ---------------------------------------------------------------- framing
def test_frame_candidates_finds_record_zero_and_stride(sample):
    data = sample.fic.read_bytes()
    cands = fr.frame_candidates(data)
    assert cands[0] == {"rec0": rec0_of(), "stride": STRIDE, "slots": 7, "count": 6}


def test_frame_fast_path_and_fallback(sample):
    data = sample.fic.read_bytes()
    expected = {"rec0": rec0_of(), "stride": STRIDE, "slots": 7, "count": 6}
    assert fr.frame(data, STRIDE, rec0_of()) == expected
    assert fr.frame(data, STRIDE, rec0_of() + 1) == expected  # wrong rec0: searched again
    assert fr.frame(data) == expected
    assert fr.frame(b"\x41" * 300) is None


def test_empty_table_needs_known_stride():
    data = make_fic([], 16)
    assert fr.frame_candidates(data) == []
    assert fr.frame_candidates(data, 16) == [{"rec0": rec0_of(), "stride": 16, "slots": 0, "count": 0}]


def test_active_records_skip_deleted_slots(sample):
    data = sample.fic.read_bytes()
    recs = list(fr.active_records(data, fr.frame(data)))
    assert [n for n, _ in recs] == [1, 2, 3, 5, 6, 7]
    assert all(len(r) == STRIDE and r[0] == fr.ACTIVE for _, r in recs)


def test_divisors():
    assert fr._divisors(12) == [1, 2, 3, 4, 6, 12]


# ---------------------------------------------------------------- formatting
@pytest.mark.parametrize(
    ("value", "text"),
    [(Decimal(0), "0"), (Decimal("12.500"), "12.5"), (Decimal("1E+3"), "1000"), (Decimal("-0.25"), "-0.25")],
)
def test_fmt_decimal(value, text):
    assert fr.fmt_decimal(value) == text


@pytest.mark.parametrize(
    ("value", "text"), [(0.0, "0"), (1.5, "1.5"), (2.0, "2"), (1e-7, "0.0000001"), (1e22, "10000000000000000000000")]
)
def test_fmt_float(value, text):
    assert fr.fmt_float(value) == text


def test_fmt_float_special_values():
    assert fr.fmt_float(float("nan")) == "nan"
    assert fr.fmt_float(float("-inf")) == "-inf"


def test_fmt_general_floats():
    assert fr.fmt_float15(0.1 + 0.2) == "0.3"
    assert fr.fmt_float15(0.0) == "0"
    assert fr.fmt_float15(1e-20) == "0.00000000000000000001"
    assert fr.fmt_float32(struct.unpack("<f", struct.pack("<f", 1.1))[0]) == "1.1"
    assert fr.fmt_float32(0.0) == "0"


def test_fixed_point_spec_and_size_of():
    assert fr.fixed_point_spec("cur4") == (8, 4)
    assert fr.fixed_point_spec("dec16_30") == (16, 30)
    assert fr.size_of({"type": "str", "size": 12}) == 12
    assert fr.size_of({"type": "dt8", "size": 99}) == 8


# ---------------------------------------------------------------- decoding
REC = (
    bytes([0x10, 0xFF])
    + struct.pack("<h", -2)
    + struct.pack("<q", -12345)
    + struct.pack("<d", 2.5)
    + struct.pack("<f", 0.5)
    + struct.pack("<BBH", 31, 12, 2023)
    + struct.pack("<BBHI", 1, 2, 2024, 3723004)
    + struct.pack("<I", 3723004)
    + bytes(range(1, 17))
    + b"abc\0zz"
    + "hi".encode("utf-16-le")
    + b"\0\0"
    + bytes(16)
    + bytes(8)
    + struct.pack("<i", -7)[:3]
)


@pytest.mark.parametrize(
    ("offset", "typ", "size", "text"),
    [
        (1, "u8", 0, "255"),
        (1, "i8", 0, "-1"),
        (2, "i16", 0, "-2"),
        (2, "u16", 0, "65534"),
        (4, "i64", 0, "-12345"),
        (4, "u64", 0, str((1 << 64) - 12345)),
        (4, "i32", 0, "-12345"),
        (4, "u32", 0, str((1 << 32) - 12345)),
        (4, "cur2", 0, "-123.45"),
        (4, "dec4_3", 0, "-12.345"),
        (12, "f64", 0, "2.5"),
        (12, "f64g", 0, "2.5"),
        (20, "f32", 0, "0.5"),
        (24, "date4", 0, "20231231"),
        (28, "dt8", 0, "20240201010203004"),
        (36, "time4", 0, "010203004"),
        (40, "uuid16", 0, "01020304-0506-0708-090a-0b0c0d0e0f10"),
        (56, "str", 0, "abc"),
        (56, "str", 3, "abc"),
        (60, "str", 0, "zzh"),
        (62, "ustr", 6, "hi"),
        (68, "uuid16", 0, ""),
        (84, "date4", 0, ""),
        (84, "dt8", 0, "00000000000000000"),
        (84, "memo", 0, ""),
    ],
)
def test_decode_and_compiled_decoder_agree(offset, typ, size, text):
    assert fr.decode(REC, offset, typ, size) == text
    if typ != "str" or size:
        assert fr.compile_decoder(typ, offset, size)(REC) == text


def test_str_without_nul_uses_whole_width():
    assert fr.decode(b"abcd", 0, "str", 4) == "abcd"
    assert fr.decode(b"abcd", 0, "str") is None  # no NUL within the probe window
    assert fr.compile_decoder("str", 0, 4)(b"abcd") == "abcd"


def test_decode_unknown_type():
    with pytest.raises(ValueError, match="bogus"):
        fr.decode(REC, 0, "bogus")


def test_fmt_scaled():
    assert fr._fmt_scaled(0, 4) == "0"
    assert fr._fmt_scaled(7, 0) == "7"
    assert fr._fmt_scaled(-50000, 4) == "-5"
    assert fr._fmt_scaled(-5, 2) == "-0.05"
    assert fr.compile_decoder("dec3_1", 0)(struct.pack("<i", -15)[:3]) == "-1.5"


# ---------------------------------------------------------------- memos
def test_memo_pointer_without_memo_file():
    rec = struct.pack("<Q", 0x300)
    assert fr.decode(rec, 0, "memo") is None
    assert fr.decode(b"\xff" * 8, 0, "memo") == ""


def test_memo_file_reads_texts(tmp_path):
    raw, heads = make_mmo([text_memo(1, 1, "hello"), b"\x01\x00\x00\x00\x0d" + bytes(14)])
    path = tmp_path / "t.mmo"
    path.write_bytes(raw)
    memo = fr.MemoFile(path)
    assert memo.text(heads[0]) == "hello"
    assert memo.text(heads[0]) == "hello"  # cached
    assert memo.text(heads[1]) is None  # binary memo
    assert memo.text(len(raw) + 10) is None  # beyond the file
    assert memo.text(0xD3) is None  # not a block start: unreadable
    assert 0xD3 in memo.cache
    assert fr.MemoFile(tmp_path / "missing.mmo").text(heads[0]) is None


# ---------------------------------------------------------------- layouts and tables
def test_fingerprint_checks(sample):
    lay = SampleTable.layout()
    data = sample.fic.read_bytes()
    lay["desc_sha1"] = fr.desc_hash(data, rec0_of())
    assert fr.check_fingerprint(sample.fic, lay)[:2] == (True, "")
    assert "record 0 moved" in fr.check_fingerprint(sample.fic, {**lay, "rec0": 10})[1]
    assert "description block changed" in fr.check_fingerprint(sample.fic, {**lay, "desc_sha1": "x"})[1]
    assert fr.check_fingerprint(sample.fic, {**lay, "stride": 7}) == (
        False,
        "framing with the learned stride failed (record size changed?)",
        None,
    )


def test_read_table_reproduces_export(sample):
    rows = list(fr.read_table(sample.fic, SampleTable.layout()))
    assert rows == sample.xml_rows
    numbered = list(fr.read_table(sample.fic, SampleTable.layout(), with_recno=True))
    assert [n for n, _ in numbered] == [1, 2, 3, 5, 6, 7]


def test_read_table_without_framing(tmp_path):
    path = tmp_path / "x.fic"
    path.write_bytes(b"\x41" * 400)
    with pytest.raises(ValueError, match="cannot frame"):
        list(fr.read_table(path, {"stride": 16, "columns": []}))


def test_read_table_null_value_of_undecodable_memo(tmp_path):
    rec = make_record(24, {8: struct.pack("<Q", 0x999)})
    path = tmp_path / "m.fic"
    path.write_bytes(make_fic([rec], 24))
    lay = {"stride": 24, "rec0": rec0_of(DESC), "columns": [{"name": "m", "offset": 8, "size": 8, "type": "memo"}]}
    assert list(fr.read_table(path, lay)) == [[("m", "")]]


def test_load_layouts_and_find_layout(tmp_path):
    path = tmp_path / "l.json"
    path.write_text('{"tables": {"Sample": {"stride": 4}}}', encoding="utf-8")
    tables = fr.load_layouts(path)["tables"]
    assert fr.find_layout(tables, "Sample") == {"stride": 4}
    assert fr.find_layout(tables, "SAMPLE") == {"stride": 4}
    assert fr.find_layout(tables, "Other") is None


def test_fic_files(sample):
    assert set(fr.fic_files(sample.data_dir)) == {"Sample", "Empty"}


def test_write_xml_round_trip(tmp_path):
    rows = [[("a", "x & <y>"), ("b", "bad \ufffd byte")], [("a", "")]]
    path = tmp_path / "T.XML"
    assert fr.write_xml(path, "T", rows) == 2
    raw = path.read_bytes()
    assert b"\x81" in raw
    assert b"\r\n" in raw
    assert list(xmlrows.rows_of(path, "T")) == rows


def test_undefined_as_byte_handler():
    assert "\ufffd€Ā".encode("cp1252", "wdmap_undefined") == b"\x81\x80?"


def test_main_prints_rows(sample, tmp_path, capsys):
    layouts = tmp_path / "layouts.json"
    lay = SampleTable.layout()
    layouts.write_text(json.dumps({"tables": {"Sample": lay}}), encoding="utf-8")
    fr.main([str(sample.fic), "--layouts", str(layouts), "--limit", "2"])
    out = capsys.readouterr()
    assert out.out.count("\n") == 2
    assert "'id': '101'" in out.out
    out_xml = tmp_path / "out.XML"
    fr.main([str(sample.fic), "--layouts", str(layouts), "--xml", str(out_xml)])
    assert "6 rows" in capsys.readouterr().out
    lay["rec0"] = 1
    layouts.write_text(json.dumps({"tables": {"Sample": lay}}), encoding="utf-8")
    fr.main([str(sample.fic), "--layouts", str(layouts), "--limit", "0"])
    out = capsys.readouterr()
    assert "warning: record 0 moved" in out.err
    assert out.out.count("\n") == 6


def test_main_without_layout(sample, tmp_path):
    layouts = tmp_path / "layouts.json"
    layouts.write_text('{"tables": {}}', encoding="utf-8")
    with pytest.raises(SystemExit, match="no layout for Sample"):
        fr.main([str(sample.fic), "--layouts", str(layouts)])

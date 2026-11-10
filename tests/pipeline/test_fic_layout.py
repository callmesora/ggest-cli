import json
import struct

import fic_layout as fl
import pytest
from pipeline_fakes import LAYOUT, STRIDE, SampleTable, make_fic, make_record, xml_text


# ---------------------------------------------------------------- values -> encodings
def test_canonical_number():
    assert fl.canonical_number("12.5")
    assert fl.canonical_number("-3")
    assert not fl.canonical_number("012")
    assert not fl.canonical_number("1.50")
    assert not fl.canonical_number("-0")


def test_type_options_for_integers():
    opts = fl.type_options(["1", "200", None])
    assert opts[:6] == ["str", "u8", "i16", "i32", "i64", "u16"]
    assert "i8" not in opts  # 200 does not fit in 7 bits
    assert "cur4" in opts
    assert opts[-1] == "memo"
    neg = fl.type_options(["-5", "7"])
    assert not [t for t in neg if t.startswith("u")]


def test_type_options_for_patterns():
    assert fl.type_options(["20240101", ""]) == ["str", "date4", "memo"]
    assert "dt8" in fl.type_options(["20240101123000000"])
    assert "time4" in fl.type_options(["123000000"])
    assert fl.type_options(["0f1e2d3c-0000-1111-2222-333344445555"]) == ["str", "uuid16", "memo"]
    assert fl.type_options(["1.50"]) == ["str", "memo"]  # not written like the reader writes numbers
    assert fl.type_options([None, None]) == ["str", "memo"]


@pytest.mark.parametrize(
    ("value", "typ", "raw"),
    [
        ("ab", "str", b"ab\0"),
        ("300", "i16", struct.pack("<h", 300)),
        ("300", "u8", None),
        ("x", "i32", None),
        ("12.5", "cur4", struct.pack("<q", 125000)),
        ("1.5", "dec3_1", (15).to_bytes(3, "little")),
        ("0.123", "cur2", None),
        ("20240131", "date4", struct.pack("<BBH", 31, 1, 2024)),
        ("", "date4", bytes(4)),
        ("20240131010203004", "dt8", struct.pack("<BBHI", 31, 1, 2024, 3723004)),
        ("", "uuid16", bytes(16)),
        ("00010203-0405-0607-0809-0a0b0c0d0e0f", "uuid16", bytes(range(16))),
        ("010203004", "time4", struct.pack("<I", 3723004)),
        ("1.5", "f64", None),
        ("Ā", "str", None),
        ("bad", "dt8", None),
    ],
)
def test_encode(value, typ, raw):
    assert fl.encode(value, typ) == raw


def test_distinguishable_keeps_preferred_encoding_per_bytes():
    opts = fl.type_options(["5"])
    kept = fl.distinguishable(opts, "5")
    assert kept[:4] == ["str", "memo", "u8", "i16"]
    assert "u32" not in kept  # same bytes and size as i32
    assert "f64" in kept
    assert fl.distinguishable(["u8", "date4"], None) == ["date4"]


def test_xml_column_order_uses_longest_row():
    rows = [[("a", "1"), ("c", "1")], [("a", "1"), ("b", "1"), ("c", "1")], [("d", "1")]]
    assert fl.xml_column_order(rows) == ["a", "b", "c", "d"]
    assert fl.xml_column_order([]) == []


def test_widths():
    assert [fl.int_width(v) for v in (5, 200, 40000, 1 << 40)] == [1, 2, 4, 8]
    assert fl.plausible_fixed(["u8", "i16", "i32"], 4, 300) == ["i16"]
    assert fl.plausible_fixed(["cur4", "dec6_4", "dec4_4"], 8, 0) == ["cur4"]
    assert fl.plausible_fixed(["dec6_4", "dec4_4"], 8, 0) == ["dec6_4", "dec4_4"]
    assert fl.plausible_fixed(["f64", "date4"], 4, 0) == ["date4"]
    assert fl.plausible_fixed(["f64"], 4, 0) == ["f64"]


def test_finish_column():
    assert fl.finish_column("s", 10, ["str"], 6, 4, True) == {"name": "s", "offset": 10, "size": 6, "type": "str"}
    assert fl.finish_column("s", 10, ["str"], 2, 4, True)["size"] == 4
    assert fl.finish_column("n", 0, ["u8", "i32"], 4, 1, True)["type"] == "i32"
    assert fl.finish_column("n", 0, ["u8", "i16"], 4, 1, False)["type"] == "u8"
    assert fl.finish_column("n", 0, ["i64"], 4, 1, True)["type"] == "i64"


# ---------------------------------------------------------------- alignment
def _records(values_at: list[dict[int, bytes]], stride: int = 24) -> list[bytes]:
    return [make_record(stride, items, recno=i + 1) for i, items in enumerate(values_at)]


def test_align_single_row():
    assert fl.align([b"x"], [], {}, 24) == ([0], {"by": [], "single_row": True})


def test_align_through_unique_column():
    recs = _records([{10: b"k3\0"}, {10: b"k1\0"}, {10: b"k2\0"}])
    vals = {"key": ["k1", "k2", "k3"]}
    m, how = fl.align(recs, ["key"], vals, 24)
    assert m == [2, 0, 1]
    assert how == {"by": ["key"], "offset": 10, "type": "str"}


def test_align_through_composite_key():
    # neither column is unique alone; together they are, except one duplicated pair
    pairs = [(1, 1), (1, 2), (1, 3), (2, 1), (2, 3), (2, 3)]
    recs = _records([{12: bytes([a]), 16: bytes([b])} for a, b in pairs])
    vals = {"a": [str(a) for a, _ in reversed(pairs)], "b": [str(b) for _, b in reversed(pairs)]}
    m, how = fl.align(recs, ["a", "b"], vals, 24)
    assert sorted(m) == [0, 1, 2, 3, 4, 5]
    assert how["composite"] is True
    assert how["by"] == ["b", "a"]  # most distinct values first
    assert how["ambiguous_rows"] == [4, 5]
    assert how["unique_rows"] == 4


def test_align_fails_without_key():
    recs = _records([{10: b"\x07"}, {10: b"\x07"}])
    assert fl.align(recs, ["c"], {"c": ["x", "y"]}, 24) == (None, None)


def test_composite_mapping_rejects_other_multisets():
    found = [("a", (12, "u8", ["1", "1"]))]
    assert fl._composite_mapping(found, {"a": ["1", "2"]}, 2) is None


# ---------------------------------------------------------------- candidates and placement
def test_probes():
    assert fl.make_probe("str", "ab", ["ab"], fuzzy=True).kind == "fuzzy"
    assert fl.make_probe("str", "ab", ["ab"], fuzzy=False).needle == b"ab\0"
    assert fl.make_probe("f64", "x", ["x"], False) is None
    assert fl.make_probe("f64", "1.5", ["1.5"], False).needle == struct.pack("<d", 1.5)
    assert fl.make_probe("memo", "", [""], False).needle is None
    assert fl.make_probe("i16", "70000", ["70000"], False) is None
    assert fl.make_probe("u8", "5", ["5", "x"], False) is None
    assert fl.make_probe("u8", "5", ["5"], False).encs == [b"\x05"]


def test_item_positions():
    assert fl.find_all(b"aXaXa", b"a") == [0, 2, 4]
    assert fl.item_positions(b"\x01" * 12, b"\x01\x01", 2, 12) == [8, 9, 10]
    assert fl.item_positions(b"", None, 4, 14) == [8, 9, 10]


def test_assigner_prefers_xml_neighbours():
    cols = ["a", "b", "c"]
    cands = {"a": {8: ["u8"]}, "b": {9: ["u8", "i16"], 12: ["u8"]}, "c": {11: ["u8"]}}
    varies = {"a": True, "b": False, "c": True}
    placed = fl.Assigner(cols, cands, {"a": 2, "b": 2, "c": 2}, varies, set(), 16).run()
    assert placed["a"] == (8, ["u8"])
    assert placed["c"] == (11, ["u8"])
    assert placed["b"][0] == 9


def test_assigner_before_next_and_fallback():
    cols = ["a", "b", "c"]
    cands = {"a": {20: ["u8"]}, "b": {8: ["i16", "u8"], 14: ["u8"]}, "c": {10: ["u8"]}}
    varies = {"a": True, "b": False, "c": True}
    placed = fl.Assigner(cols, cands, dict.fromkeys(cols, 2), varies, set(), 24).run()
    assert placed["b"] == (8, ["i16"])  # ends where the next XML column starts
    solo = fl.Assigner(["x"], {"x": {8: ["u8"], 12: ["i32"]}}, {"x": 2}, {"x": False}, set(), 24)
    assert solo.neighbour_choice("x", [(8, ["u8"]), (12, ["i32"])]) == (12, ["i32"])


def test_assigner_propagation_and_widths():
    cols = ["a", "b", "c", "d"]
    cands = {
        "a": {8: ["u8", "i16", "i32"], 30: ["u8"]},
        "b": {12: ["cur4", "dec6_4"]},
        "c": {20: ["i16", "i32", "u8"]},
        "d": {},
    }
    varies = dict.fromkeys(cols, True)
    asg = fl.Assigner(cols, cands, dict.fromkeys(cols, 2), varies, {("a", 30, "u8")}, 32, {"c": 1000})
    placed = asg.run()
    assert placed["a"] == (8, ["i32"])  # exact fit up to its XML successor
    assert placed["b"] == (12, ["cur4"])
    assert placed["c"] == (20, ["i16"])  # by magnitude
    assert "d" not in placed


def test_column_stats_and_best_per_size():
    xc = ["5", "5", "5"]
    st = fl.column_stats(xc, [0, 1, 2], [0])
    assert not st.varies
    assert st.maxabs == 5
    assert st.rows == [0]
    st2 = fl.column_stats(["a", "b", None], [0, 1, 2], [0])
    assert st2.varies
    assert st2.rows == [0, 1, 2]
    assert st2.minw == 2
    assert fl.best_per_size(["u32", "i32", "str", "u8"], 3) == ["str", "u8", "i32"]
    assert fl.first_rows_per_value(["a", "a", "b", "c"], [0, 1, 2, 3], limit=2) == [0, 2]


def test_count_mismatches_and_null_bit():
    f = {b"a": "1", b"b": "2", b"c": None}.get
    xc = ["1", "9", None, "3"]
    recs = [b"a", b"b", b"x", b"c"]
    assert fl.count_mismatches(f, xc, recs, [0, 1, 2, 3], stop_at_first=True) == (1, ["9", "2"])
    assert fl.count_mismatches(f, xc, recs, [0, 1, 2, 3], stop_at_first=False) == (2, ["9", "2"])
    recs8 = [bytes(8) + b"\xff", bytes(8) + b"\xfb"]
    assert fl.null_bit(recs8, [False, True], 8) == 2
    assert fl.null_bit(recs8, [True, True], 8) is None


def test_has_null_bit_and_unplaced():
    assert fl.has_null_bit({"null_bit": 0})
    assert fl.has_null_bit({"null_bit_unknown": True})
    assert not fl.has_null_bit({})
    assert fl.unplaced(["a", "b"], [{"name": "a"}]) == ["b"]


# ---------------------------------------------------------------- whole tables
def test_learn_sample_table(sample):
    res = fl.Table("Sample", sample.fic, sample.xml).learn()
    assert "error" not in res
    got = {c["name"]: (c["offset"], c["type"]) for c in res["columns"]}
    for name, off, _, typ in LAYOUT:
        if name != "flag":  # constant in the data: its encoding is a guess
            assert got[name] == (off, typ)
    note = next(c for c in res["columns"] if c["name"] == "note")
    assert note["null_bit"] == 5
    assert res["failed_columns"] == []
    assert res["unmatched"] == []


def test_learn_errors(tmp_path, sample):
    junk = tmp_path / "Junk.fic"
    junk.write_bytes(b"\x41" * 300)
    assert fl.Table("Sample", junk, sample.xml).learn()["error"] == "no framing"
    two = tmp_path / "Two.fic"
    two.write_bytes(make_fic([make_record(STRIDE, {}), make_record(STRIDE, {}, recno=2)], STRIDE))
    assert fl.Table("Sample", two, sample.xml).learn()["error"] == "active records 2 != XML rows 6"
    xml = tmp_path / "Two.XML"
    xml.write_bytes(xml_text("Two", [[("c", "x")], [("c", "y")]]))
    assert fl.Table("Two", two, xml).learn()["error"] == "alignment failed"


def test_learn_marks_failed_columns(tmp_path):
    recs = [make_record(24, {10: bytes([i]), 12: b"\x07"}, recno=i + 1) for i in (1, 2, 3)]
    fic = tmp_path / "T.fic"
    fic.write_bytes(make_fic(recs, 24))
    xml = tmp_path / "T.XML"
    xml.write_bytes(xml_text("T", [[("k", str(i)), ("v", "7" if i < 3 else "8")] for i in (1, 2, 3)]))
    res = fl.Table("T", fic, xml).learn()
    assert res["alignment"]["by"] == ["k"]
    assert "v" in res["unmatched"] or "v" in res["failed_columns"]


def test_learn_ambiguous_rows_only(tmp_path):
    recs = [make_record(24, {12: bytes([v])}, recno=i + 1) for i, v in enumerate((1, 1, 2, 2))]
    fic = tmp_path / "T.fic"
    fic.write_bytes(make_fic(recs, 24))
    xml = tmp_path / "T.XML"
    xml.write_bytes(xml_text("T", [[("c", v)] for v in ("1", "1", "2", "2")]))
    assert fl.Table("T", fic, xml).learn()["error"] == "no unambiguous rows"


def test_update_null_bits(sample):
    t = fl.Table("Sample", sample.fic, sample.xml)
    recs, xv = t.update_null_bits()
    assert len(recs) == 6
    assert xv["note"][1] is None
    lay = {"columns": [{"name": "note"}, {"name": "id"}]}
    t.null_bits(lay, recs, xv)
    assert lay["columns"] == [{"name": "note", "null_bit": 5}, {"name": "id"}]
    same = [bytes(8) + bytes([255]) * 72] * 2  # identical records: no bit tells the rows apart
    t.null_bits(lay, same, {"note": ["a", "b"], "id": [None, "1"]})
    assert lay["columns"][1] == {"name": "id", "null_bit_unknown": True}


def test_update_null_bits_without_alignment(tmp_path):
    recs = [make_record(24, {12: b"\x01"}, recno=i + 1) for i in range(2)]
    fic = tmp_path / "T.fic"
    fic.write_bytes(make_fic(recs, 24))
    xml = tmp_path / "T.XML"
    xml.write_bytes(xml_text("T", [[("c", "x")], [("c", "y")]]))
    assert fl.Table("T", fic, xml).update_null_bits() is None


# ---------------------------------------------------------------- command line
def test_main_learns_and_merges(sample, tmp_path, capsys):
    out = tmp_path / "out" / "layouts.json"
    fl.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--out", str(out)])
    doc = json.loads(out.read_text(encoding="utf-8"))
    assert set(doc["tables"]) == {"Empty", "Sample"}
    assert doc["tables"]["Empty"]["status"] == "EMPTY_OR_NO_EXPORT"
    assert len(doc["tables"]["Empty"]["empty_sha1"]) == 40
    assert doc["tables"]["Sample"]["xml_rows"] == 6
    assert doc["layout_version"] == fl.LAYOUT_VERSION
    assert "Sample\trows=6\tcols=9/9" in capsys.readouterr().out
    fl.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--out", str(out),
             "--tables", "Missing,Sample", "--merge"])  # fmt: skip
    assert "Missing no .fic" in capsys.readouterr().out
    assert set(json.loads(out.read_text(encoding="utf-8"))["tables"]) == {"Empty", "Sample"}


def test_main_records_learning_errors(sample, tmp_path, monkeypatch):
    def boom(self):
        raise RuntimeError("bad data")

    monkeypatch.setattr(fl.Table, "learn", boom)
    out = tmp_path / "layouts.json"
    fl.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--out", str(out), "--tables", "Sample"])
    entry = json.loads(out.read_text(encoding="utf-8"))["tables"]["Sample"]
    assert entry == {"table": "Sample", "error": "RuntimeError: bad data", "columns": []}


def test_main_update_null_bits(sample, tmp_path, capsys):
    lay = SampleTable.layout()
    del lay["columns"][6]["null_bit"]
    other = {"columns": [{"name": "c"}], "xml_columns": ["c"]}
    (sample.xml_dir / "Full.XML").write_bytes(xml_text("Full", [[("c", "1")]]))  # complete rows: nothing to do
    tables = {"Sample": lay, "Empty": {"columns": []}, "Other": other, "Full": other}
    out = tmp_path / "layouts.json"
    out.write_text(json.dumps({"tables": tables}), encoding="utf-8")
    fl.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--out", str(out), "--update-null-bits"])
    assert "Sample [('note', 5)]" in capsys.readouterr().out
    assert json.loads(out.read_text(encoding="utf-8"))["tables"]["Sample"]["columns"][6]["null_bit"] == 5

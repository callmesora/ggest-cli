import sqlite3
from pathlib import Path

import build_sqlite as bs
import pytest
from pipeline_fakes import PNG_BYTES, binary_memo, make_mmo, named_memo, text_memo, xml_text


class FakeBi:
    def __init__(self, error=None):
        self.path, self.error = None, error

    def set_db(self, path):
        self.path = path

    def build_views(self):
        if self.error:
            raise self.error


@pytest.fixture
def fake_bi(monkeypatch):
    bi = FakeBi()
    monkeypatch.setattr(bs, "bidb", bi)
    return bi


def test_build(sample, tmp_path, fake_bi, capsys):
    out = tmp_path / "out"
    bs.main([str(sample.xml_dir), str(sample.data_dir), str(out)])
    db = sqlite3.connect(out / "data.sqlite")
    assert db.execute("SELECT name, rows, columns, export_status FROM _tables ORDER BY name").fetchall() == [
        ("Empty", 0, 0, "EMPTY_OR_NO_EXPORT"),
        ("Sample", 6, 9, "OK"),
    ]
    row = db.execute('SELECT _row, id, name, note FROM "Sample" WHERE _row = 2').fetchone()
    assert row == (2, "102", "Gadget <x>", None)
    assert db.execute("SELECT count(*) FROM _memo_texts").fetchone() == (3,)
    db.close()
    assert fake_bi.path.endswith("data.sqlite.building")
    assert not (out / "data.sqlite.building").exists()
    assert "done" in capsys.readouterr().out


def test_only_exported_and_no_memos(sample, tmp_path, fake_bi):
    out = tmp_path / "out"
    bs.main([str(sample.xml_dir), str(sample.data_dir), str(out), "--only-exported", "--no-memos"])
    db = sqlite3.connect(out / "data.sqlite")
    assert db.execute("SELECT name FROM _tables").fetchall() == [("Sample",)]
    assert db.execute("SELECT count(*) FROM _memo_texts").fetchone() == (0,)
    db.close()


def test_views_failure_is_reported(sample, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(bs, "bidb", FakeBi(sqlite3.OperationalError("no such table")))
    bs.main([str(sample.xml_dir), str(sample.data_dir), str(tmp_path / "out"), "--only-exported"])
    assert "business views skipped: no such table" in capsys.readouterr().out


def test_batches_and_late_columns(tmp_path, monkeypatch):
    monkeypatch.setattr(bs, "BATCH", 2)
    xml = tmp_path / "T.XML"
    xml.write_bytes(xml_text("T", [[("a", "1")], [("a", "2")], [("a", "3"), ("b", "x")], [("b", "y")]]))
    db = sqlite3.connect(":memory:")
    assert bs.load_table(db, "T", xml) == (4, 2)
    assert db.execute('SELECT * FROM "T" ORDER BY _row').fetchall() == [
        (1, "1", None),
        (2, "2", None),
        (3, "3", "x"),
        (4, None, "y"),
    ]


def test_memos(tmp_path, capsys):
    blob = b"\x01" + bytes(18) + (4).to_bytes(4, "little") + bytes(4) + b"DATA"
    memos = [text_memo(1, 3, "hello"), binary_memo(2, 3, PNG_BYTES), named_memo(4, "", "pic.dat", blob),
             binary_memo(5, 3, b""), b"\x01\x00\x00\x00\x0c"]  # fmt: skip
    raw, heads = make_mmo(memos)
    mmo = tmp_path / "T.mmo"
    mmo.write_bytes(raw)
    db = sqlite3.connect(":memory:")
    for sql in bs.META:
        db.execute(sql)
    out = tmp_path / "out"
    bs.load_memos(db, "T", mmo, out)
    assert db.execute("SELECT * FROM _memo_texts").fetchall() == [("T", 3, 1, "hello")]
    files = db.execute("SELECT rec, item, ext, original_name, path, bytes FROM _memo_files ORDER BY item").fetchall()
    path = str(Path("memo_files", "T", f"rec3_item2_off{heads[1]:x}.png"))
    assert files[0] == (3, 2, "png", "", path, len(PNG_BYTES))
    assert files[1][:4] == (None, 4, "bin", "pic.dat")
    assert (out / files[1][4]).read_bytes() == b"DATA"
    assert "memo error" in capsys.readouterr().out
    mmo.write_bytes(bytes(0xD2) + bytes(30))
    bs.load_memos(db, "T", mmo, out)
    assert "memo walk error" in capsys.readouterr().out


def test_quote():
    assert bs.q('a"b') == '"a""b"'

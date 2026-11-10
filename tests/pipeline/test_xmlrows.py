import xmlrows
from pipeline_fakes import xml_text


def test_rows_across_chunks(tmp_path, monkeypatch):
    rows = [[("a", str(i)), ("b", f"v&{i}")] for i in range(50)] + [[("b", "only b")]]
    path = tmp_path / "T.XML"
    path.write_bytes(xml_text("T", rows))
    monkeypatch.setattr(xmlrows, "CHUNK", 7)  # rows split across reads
    assert list(xmlrows.rows_of(path, "T")) == rows


def test_first_seen_columns():
    assert xmlrows.first_seen_columns([[("b", "1")], [("a", "1"), ("b", "2"), ("c", "")]]) == ["b", "a", "c"]


def test_xml_files(tmp_path):
    (tmp_path / "Sales.XML").write_text("x")
    (tmp_path / "Sales.xsl").write_text("x")
    assert xmlrows.xml_files(tmp_path) == {"sales": tmp_path / "Sales.XML"}


def test_export_statuses(tmp_path):
    (tmp_path / "_log_worker1.tsv").write_text("A\t1\tOK\t1\t0\nB\t1\tTIMEOUT\t0\t0\nshort\n", encoding="utf-8")
    (tmp_path / "_log_worker2.tsv").write_text("\ufeffA\t1\tFAILED\nB\t1\tOK\n", encoding="utf-8")
    (tmp_path / "other.tsv").write_text("C\t1\tOK\n", encoding="utf-8")
    assert xmlrows.export_statuses(tmp_path) == {"A": "OK", "B": "OK"}
    assert xmlrows.export_statuses(tmp_path / "missing") == {}

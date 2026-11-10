import collections
import json

import fic_reader
import pytest
import validate_reader as vr
from pipeline_fakes import SampleTable, rec0_of


@pytest.fixture
def layout(sample):
    lay = SampleTable.layout()
    lay["desc_sha1"] = fic_reader.desc_hash(sample.fic.read_bytes(), rec0_of())
    return lay


def test_exact_table(sample, layout):
    r = vr.validate_table("Sample", sample.fic, sample.xml, layout)
    assert (r["status"], r["rows_matched"], r["native_rows"], r["bad_columns"], r["detail"]) == ("exact", 6, 6, 0, "")


def test_partial_table_reports_columns(sample, layout):
    layout["columns"][2]["type"] = "cur2"  # price read with the wrong scale
    del layout["columns"][-1]  # flag not read
    r = vr.validate_table("Sample", sample.fic, sample.xml, layout)
    assert r["status"] == "failed"
    assert r["detail"].startswith("missing columns: flag; price[")
    layout["columns"][2]["type"] = "cur4"
    r = vr.validate_table("Sample", sample.fic, sample.xml, layout)
    assert r["status"] == "failed"
    assert r["detail"].startswith("missing columns: flag; flag[6]")


def test_layout_problems(sample, layout):
    assert vr.validate_table("Sample", sample.fic, sample.xml, None)["detail"] == "no layout"
    assert vr.validate_table("Sample", sample.fic, sample.xml, {"error": "boom"})["detail"] == "boom"
    moved = {**layout, "rec0": 7}
    assert vr.validate_table("Sample", sample.fic, sample.xml, moved)["detail"].startswith("fingerprint: record 0")
    broken = {**layout, "columns": [{"name": "id", "offset": 10, "size": 4, "type": "bogus"}]}
    assert vr.validate_table("Sample", sample.fic, sample.xml, broken)["detail"] == "read error KeyError: 'bogus'"


def test_row_status_and_detail():
    assert vr.row_status(3, 3, 3) == "exact"
    assert vr.row_status(2, 3, 3) == "partial"
    assert vr.row_status(0, 3, 3) == "failed"
    assert vr.detail([], ["a", "b"]) == "a | b"
    xt = collections.Counter([("1", "x"), ("2", "y")])
    nt = collections.Counter([("1", "x"), ("2", "z")])
    assert vr.bad_columns(["k", "v"], xt, nt) == ["v[1] xml=['y'] native=['z']"]


def test_tsv_and_summary(tmp_path):
    results = [
        {"table": "A", "status": "exact", "xml_rows": 2, "native_rows": 2, "rows_matched": 2, "detail": "",
         "bad_columns": 0},
        {"table": "B", "status": "partial", "xml_rows": 3, "native_rows": 3, "rows_matched": 1,
         "detail": "x\ty\nz"},
    ]  # fmt: skip
    out = tmp_path / "sub" / "validation.tsv"
    vr.write_tsv(out, results)
    lines = out.read_text(encoding="utf-8").splitlines()
    assert lines[0] == vr.TSV_HEADER.strip()
    assert lines[2] == "B\tpartial\t3\t3\t1\t\tx y z"
    assert vr.summary(results) == [
        "\n2 tables with rows: 1 exact, 1 partial, 0 failed",
        "rows matched exactly: 3 of 5; rows in 100%-exact tables: 2",
    ]


def test_main(sample, layout, tmp_path, capsys):
    layouts = tmp_path / "layouts.json"
    layouts.write_text(json.dumps({"tables": {"Sample": layout}}), encoding="utf-8")
    (sample.xml_dir / "Empty.XML").write_bytes(b"<HF_DOCUMENT></HF_DOCUMENT>")
    out = tmp_path / "validation.tsv"
    vr.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--layouts", str(layouts),
             "--out", str(out)])  # fmt: skip
    printed = capsys.readouterr().out
    assert "exact    Sample" in printed
    assert "1 tables with rows: 1 exact" in printed
    assert out.read_text(encoding="utf-8").splitlines()[1] == "Sample\texact\t6\t6\t6\t0\t"
    sample.xml.with_name("Lost.XML").write_bytes(b"")
    vr.main(["--data", str(sample.data_dir), "--xml", str(sample.xml_dir), "--layouts", str(layouts),
             "--out", str(out), "--tables", "Lost,Empty"])  # fmt: skip
    assert out.read_text(encoding="utf-8").splitlines() == [vr.TSV_HEADER.strip()]

import json

import fic_reader
import native_export as ne
import pytest
import xmlrows
from pipeline_fakes import SampleTable, make_fic, rec0_of


@pytest.fixture
def setup(sample, tmp_path):
    lay = SampleTable.layout()
    lay["desc_sha1"] = fic_reader.desc_hash(sample.fic.read_bytes(), rec0_of())
    empty_sha = ne.sha1(sample.data_dir / "Empty.fic")
    layouts = {"Sample": lay, "Empty": {"columns": [], "empty_sha1": empty_sha}}
    lpath = tmp_path / "layouts.json"
    lpath.write_text(json.dumps({"tables": layouts}), encoding="utf-8")
    vpath = tmp_path / "validation.tsv"
    vpath.write_text("table\tstatus\nSample\texact\n", encoding="utf-8")
    return sample, lpath, vpath, layouts


def test_export_reads_valid_tables(setup, tmp_path):
    sample, lpath, vpath, _ = setup
    out = tmp_path / "out"
    logged = []
    done, fallback = ne.export(sample.data_dir, out, None, lpath, vpath, log=logged.append)
    assert (done, fallback) == (["Empty", "Sample"], {})
    assert list(xmlrows.rows_of(out / "Sample.XML", "Sample")) == sample.xml_rows
    statuses = xmlrows.export_statuses(out)
    assert statuses == {"Empty": "EMPTY_OR_NO_EXPORT", "Sample": "OK"}
    assert "native reader: 2 tables" in logged[0]


def test_fallback_reasons(setup, tmp_path):
    sample, _, _, layouts = setup
    fic = sample.fic
    lay = layouts["Sample"]
    assert ne.export_table("S", fic, None, "exact", tmp_path) == (None, "no layout (new table?)")
    assert ne.export_table("S", fic, lay, "partial", tmp_path) == (None, "validation status partial")
    moved = {**lay, "rec0": 3}
    assert ne.export_table("S", fic, moved, "exact", tmp_path)[1].startswith("fingerprint changed: record 0 moved")
    bad = {**lay, "columns": [{"name": "x", "offset": 10, "size": 4, "type": "bogus"}]}
    assert ne.export_table("S", fic, bad, "exact", tmp_path) == (None, "read error KeyError: 'bogus'")
    changed = {"columns": [], "empty_sha1": "0" * 40}
    assert ne.export_table("E", fic, changed, "exact", tmp_path) == (
        None,
        "table had no rows when learned and has changed",
    )
    assert ne.export_table("E", fic, {"columns": [], "error": "no framing"}, "x", tmp_path) == (None, "no framing")


def test_table_without_active_rows_is_empty(tmp_path):
    fic = tmp_path / "Z.fic"
    fic.write_bytes(make_fic([bytes([0x80]) + bytes(15)], 16))
    lay = {"stride": 16, "rec0": rec0_of(), "columns": [{"name": "a", "offset": 8, "size": 1, "type": "u8"}]}
    line, reason = ne.export_table("Z", fic, lay, "exact", tmp_path)
    assert reason is None
    assert line.startswith(f"Z\t{fic.stat().st_size}\tEMPTY_OR_NO_EXPORT\t0\t")
    assert not (tmp_path / "Z.XML").exists()


def test_load_validation(tmp_path):
    assert ne.load_validation(tmp_path / "missing.tsv") == {}


def test_main(setup, tmp_path, capsys):
    sample, lpath, _, _ = setup
    out = tmp_path / "out"
    ne.main([str(sample.data_dir), str(out), "--tables", "Sample", "--layouts", str(lpath),
             "--validation", str(tmp_path / "none.tsv")])  # fmt: skip
    assert "fallback Sample: validation status missing" in capsys.readouterr().out
    assert json.loads((out / "_native_export.json").read_text()) == {
        "native": [],
        "fallback": {"Sample": "validation status missing"},
    }

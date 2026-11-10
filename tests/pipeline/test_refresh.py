import json
import subprocess
import sys
from pathlib import Path

import fic_reader
import pytest
import refresh
from pipeline_fakes import SampleTable, rec0_of


@pytest.fixture
def layouts(tmp_path):
    lay_dir = tmp_path / "layouts"
    lay_dir.mkdir()
    (lay_dir / "ggest_layouts.json").write_text(json.dumps({"tables": {"Old": {"columns": [1]}}}), encoding="utf-8")
    refresh.write_validation(lay_dir / "validation.tsv", {"Old": {"table": "Old", "status": "exact"}})
    return lay_dir


def test_validation_round_trip(tmp_path):
    path = tmp_path / "v.tsv"
    refresh.write_validation(path, {"A": {"table": "A", "status": "exact", "xml_rows": 3}})
    assert (
        path.read_bytes()
        == b"table\tstatus\txml_rows\tnative_rows\trows_matched\tbad_columns\tdetail\nA\texact\t3\t\t\t\t\n"
    )
    assert refresh.read_tsv(path)["A"]["xml_rows"] == "3"


def test_merge_relearned_keeps_exact_and_empty_tables():
    new = {"Good": {"columns": [1]}, "Bad": {"columns": [1]}, "Empty": {"columns": [], "empty_sha1": "x"}}
    val = {"Good": {"table": "Good", "status": "exact"}, "Bad": {"table": "Bad", "status": "partial"}}
    doc, vrows = {"tables": {}}, {}
    assert refresh.merge_relearned(new, val, doc, vrows) == ["Good", "Empty"]
    assert set(doc["tables"]) == {"Good", "Empty"}
    assert set(vrows) == {"Good"}


def test_relearn_merges_validated_layouts(layouts, monkeypatch, capsys):
    def fake(fic_dir, xml_dir, names, tmp, tval):
        tmp.write_text(json.dumps({"tables": {"New": {"columns": [2]}, "Off": {"columns": [3]}}}), encoding="utf-8")
        refresh.write_validation(tval, {"New": {"table": "New", "status": "exact"}})
        return True

    monkeypatch.setattr(refresh, "_learn_and_validate", fake)
    refresh.relearn(layouts, layouts, ["New", "Off"], layouts)
    doc = json.loads((layouts / "ggest_layouts.json").read_text(encoding="utf-8"))
    assert set(doc["tables"]) == {"Old", "New"}
    assert set(refresh.read_tsv(layouts / "validation.tsv")) == {"Old", "New"}
    assert (layouts / "ggest_layouts.json.bak").exists()
    assert not (layouts / "_relearn.json").exists()
    assert "re-learned 1 table(s): New" in capsys.readouterr().out


def test_relearn_failure_and_nothing_to_do(layouts, monkeypatch, capsys):
    refresh.relearn(layouts, layouts, [], layouts)
    assert capsys.readouterr().out == ""
    monkeypatch.setattr(refresh, "_learn_and_validate", lambda *_: False)
    refresh.relearn(layouts, layouts, ["X"], layouts)
    assert "re-learning failed" in capsys.readouterr().out


def test_learn_and_validate_runs_both_scripts(tmp_path, monkeypatch):
    calls = []

    def run(args, **kw):
        calls.append(args)
        if "fic_layout.py" in args[1]:
            (tmp_path / "t.json").write_text("{}")
        return subprocess.CompletedProcess(args, 0)

    monkeypatch.setattr(refresh.subprocess, "run", run)
    assert refresh._learn_and_validate(tmp_path, tmp_path, ["A", "B"], tmp_path / "t.json", tmp_path / "v.tsv")
    assert [Path(c[1]).name for c in calls] == ["fic_layout.py", "validate_reader.py"]
    assert calls[0][0] == sys.executable
    assert "A,B" in calls[1]
    monkeypatch.setattr(refresh.subprocess, "run", lambda args, **_: subprocess.CompletedProcess(args, 1))
    assert not refresh._learn_and_validate(tmp_path, tmp_path, ["A"], tmp_path / "t2.json", tmp_path / "v.tsv")


def test_export_and_summary(tmp_path, monkeypatch):
    started = []

    class Proc:
        def __init__(self, args):
            started.append(args)

        def wait(self):
            return 0

    monkeypatch.setattr(refresh.subprocess, "Popen", Proc)
    refresh.export(tmp_path, tmp_path, 2, ["A", "B"])
    assert [a[-1] for a in started] == ["0", "1"]
    assert "-Tables" in started[0]
    assert refresh.export_summary({"A": "OK", "B": "EMPTY_OR_NO_EXPORT", "C": "FAILED"}) == (
        "1 tables exported, 1 empty, 1 failed ['C']"
    )


def test_retry_failed(tmp_path, monkeypatch):
    (tmp_path / "_log_worker0.tsv").write_text("A\t1\tFAILED\n", encoding="utf-8")
    retried = []

    def fake_export(fic_dir, xml_dir, workers, tables):
        retried.append((workers, tables))
        (xml_dir / "_log_worker9.tsv").write_text("A\t1\tOK\n", encoding="utf-8")

    monkeypatch.setattr(refresh, "export", fake_export)
    assert refresh.retry_failed(tmp_path, tmp_path) == {"A": "OK"}
    assert retried == [(1, ["A"])]


def test_build_and_dashboards(tmp_path, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(refresh.subprocess, "run", lambda args, **_: calls.append(args))
    refresh.build(tmp_path, tmp_path, str(tmp_path / "out"), True, tmp_path / "log.tsv")
    assert calls[-1][-1] == "--only-exported"
    refresh.dashboards(str(tmp_path), skip=False)
    assert "dashboard datasets skipped" in capsys.readouterr().out
    refresh.dashboards(str(refresh.PROJECT / "data"), skip=False)
    assert calls[-1][1].endswith("export_datasets.py")


def test_main_native(sample, tmp_path, monkeypatch, capsys):
    lay = SampleTable.layout()
    lay["desc_sha1"] = fic_reader.desc_hash(sample.fic.read_bytes(), rec0_of())
    layouts = tmp_path / "l.json"
    layouts.write_text(json.dumps({"tables": {"Sample": lay}}), encoding="utf-8")
    validation = tmp_path / "v.tsv"
    validation.write_text("table\tstatus\nSample\texact\n", encoding="utf-8")
    real_export = refresh.native_export.export

    def native(fic_dir, xml_dir, tables, log):
        return real_export(fic_dir, xml_dir, tables, layouts, validation, log=log)

    built, wdmap, relearned = [], [], []
    monkeypatch.setattr(refresh.native_export, "export", native)
    monkeypatch.setattr(refresh, "export", lambda *a: wdmap.append(a))
    monkeypatch.setattr(refresh, "build", lambda *a: built.append(a))
    monkeypatch.setattr(refresh, "relearn", lambda *a: relearned.append(a))
    work = tmp_path / "work"
    refresh.main(["--source", str(sample.data_dir), "--reader", "native", "--out", str(tmp_path / "out"),
                  "--work", str(work), "--tables", "Sample,Empty"])  # fmt: skip
    out = capsys.readouterr().out
    assert "WDMap fallback: Empty (no layout (new table?))" in out
    assert wdmap[0][3] == ["Empty"]
    assert relearned[0][2] == []  # Empty has no export status (the fake WDMap did nothing)
    assert built[0][3] is True
    (run_dir,) = work.iterdir()
    assert not (run_dir / "fic").exists()
    assert (run_dir / "xml" / "Sample.XML").exists()
    assert "some tables failed" not in out


def test_main_without_fic_files(tmp_path):
    with pytest.raises(SystemExit, match=r"no .fic files"):
        refresh.main(["--source", str(tmp_path)])

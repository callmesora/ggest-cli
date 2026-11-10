"""Fixtures: a throwaway app database, the synthetic gGest database and a scripted fake OpenRouter."""

import importlib.util
import sqlite3
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
from assistant_fakes import FakeOpenRouter

from bi import dates, db

_spec = importlib.util.spec_from_file_location("bi_fixtures", Path(__file__).parents[1] / "bi" / "conftest.py")
bi_fixtures = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bi_fixtures)


@pytest.fixture
def app_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "assistant.sqlite"
    monkeypatch.setenv("GGEST_APP_DB", str(path))
    return path


@pytest.fixture
def gdb(tmp_path: Path) -> Iterator[Path]:
    """The synthetic gGest database used by the bi tests (fake names and figures)."""
    path = tmp_path / "data.sqlite"
    con = sqlite3.connect(path)
    bi_fixtures.fill(con)
    con.close()
    dates._words_for_db.cache_clear()
    yield path
    db.set_db(None)
    dates._words_for_db.cache_clear()


@pytest.fixture
def fake_router() -> Callable[..., FakeOpenRouter]:
    return FakeOpenRouter

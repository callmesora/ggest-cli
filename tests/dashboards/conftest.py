"""Fixtures for the dashboard exporter tests: a fake saved-query / SQL backend with tiny synthetic rows."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # the project root (bi/, dashboards/)
from bi import db, saved
from dashboards.common import Context


class FakeBackend:
    """Answers ``run_saved_query`` from a dict of name -> rows and records every call."""

    def __init__(self) -> None:
        self.saved: dict[str, list[dict[str, Any]]] = {}
        self.sql: list[tuple[str, list[dict[str, Any]]]] = []  # (substring of the SQL, rows) pairs
        self.calls: list[tuple[str, Any, dict[str, Any]]] = []

    def run_saved_query(self, name: str, params: Any = None, **kwargs: Any) -> list[dict[str, Any]]:
        self.calls.append((name, params, kwargs))
        return [dict(r) for r in self.saved[name]]

    def rows(self, sql: str, params: Any = ()) -> list[dict[str, Any]]:
        self.calls.append((sql, params, {}))
        for needle, rows in self.sql:
            if needle in sql:
                return [dict(r) for r in rows]
        raise AssertionError(f"unexpected SQL: {sql}")


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch) -> FakeBackend:
    """Replace bi.saved.run_saved_query and bi.db.rows with a FakeBackend."""
    backend = FakeBackend()
    monkeypatch.setattr(saved, "run_saved_query", backend.run_saved_query)
    monkeypatch.setattr(db, "rows", backend.rows)
    return backend


@pytest.fixture
def ctx() -> Context:
    """Cut-off 7 March 2026."""
    return Context.from_last("2026-03-07")


@pytest.fixture
def cut() -> date:
    return date(2026, 3, 7)

"""Pipeline tests: the pipeline scripts import their siblings by module name, so put pipeline/ on sys.path.

All data here is synthetic (tiny fake .fic/.mmo/XML files built in the tests).
"""

import sys
from pathlib import Path

import pytest

PIPELINE = Path(__file__).resolve().parents[2] / "pipeline"
sys.path.insert(0, str(PIPELINE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from pipeline_fakes import SampleTable  # noqa: E402


@pytest.fixture
def sample(tmp_path: Path) -> SampleTable:
    """A small synthetic table written as .fic/.mmo + WDMap-style XML under tmp_path."""
    return SampleTable.write(tmp_path)

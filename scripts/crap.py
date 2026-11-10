"""CRAP score per function: complexity^2 * (1 - coverage)^3 + complexity.

High when a function is both complex and poorly tested. Needs a coverage JSON report:

    uv run pytest --cov --cov-report=json
    uv run python scripts/crap.py [--max 30] [--top 15]

Exit code 1 when any function scores above --max.
"""

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from radon.complexity import cc_visit

ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Score:
    name: str
    complexity: int
    coverage: float

    @property
    def crap(self) -> float:
        return self.complexity**2 * (1 - self.coverage) ** 3 + self.complexity


def function_coverage(start: int, end: int, executed: set[int], missing: set[int]) -> float:
    """Share of the function's executable lines that ran (1.0 when it has none)."""
    lines = {n for n in range(start, end + 1) if n in executed or n in missing}
    return len(lines & executed) / len(lines) if lines else 1.0


def scores(report: dict) -> list[Score]:
    out = {}
    for file, data in report["files"].items():
        executed, missing = set(data["executed_lines"]), set(data["missing_lines"])
        source = (ROOT / file).read_text(encoding="utf-8")
        for block in cc_visit(source):
            for fn in [block, *getattr(block, "methods", [])]:
                cov = function_coverage(fn.lineno, fn.endline, executed, missing)
                name = f"{file}:{fn.lineno} {fn.fullname}"  # radon lists methods twice: keep one
                out[name] = Score(name, fn.complexity, cov)
    return sorted(out.values(), key=lambda s: s.crap, reverse=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--report", type=Path, default=ROOT / "coverage.json")
    parser.add_argument("--max", type=float, default=30.0, help="highest acceptable CRAP score")
    parser.add_argument("--top", type=int, default=15, help="how many functions to list")
    args = parser.parse_args()
    results = scores(json.loads(args.report.read_text(encoding="utf-8")))
    print(f"{'CRAP':>7}  {'CC':>3}  {'COV':>5}  function")
    for s in results[: args.top]:
        print(f"{s.crap:7.1f}  {s.complexity:3d}  {s.coverage:5.0%}  {s.name}")
    over = [s for s in results if s.crap > args.max]
    print(f"\n{len(results)} functions, {len(over)} above CRAP {args.max:g}")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())

"""Tool registry shared by the CLI (bi.cli) and the MCP server (bi.mcp_server).

A tool is a plain typed function. Its signature is the contract: `Literal[...]` gives the allowed values,
`Annotated[..., Field(description=...)]` documents a parameter, and parameters without a default are required.
The CLI builds click options and the MCP server builds JSON schemas from the same signature.
"""

import inspect
from collections.abc import Callable
from dataclasses import dataclass
from typing import Annotated, Any, Literal, get_args, get_origin

from pydantic import Field

from . import dates

DateArg = Annotated[
    str | None,
    Field(description="ISO date YYYY-MM-DD (inclusive) or a date word (today, year_start, last_year_start, ...); "
                      "omit for all time"),
]  # fmt: skip
LimitArg = Annotated[int, Field(description="maximum number of rows")]


@dataclass(frozen=True)
class Tool:
    name: str
    fn: Callable[..., Any]
    description: str

    def call(self, **kwargs: Any) -> Any:
        """Run the tool with date words resolved (today, this_year, ...)."""
        return self.fn(**dates.resolve(kwargs))


TOOLS: dict[str, Tool] = {}


def tool(description: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Register a function as a tool (CLI command and MCP tool) under its own name."""

    def register(fn: Callable[..., Any]) -> Callable[..., Any]:
        TOOLS[fn.__name__] = Tool(fn.__name__, fn, description)
        return fn

    return register


@dataclass(frozen=True)
class Param:
    """One tool parameter, read from the function signature."""

    name: str
    kind: type | None  # int, float, bool, str, dict (None: any)
    choices: tuple[str, ...] | None
    description: str
    required: bool
    default: Any


def _unwrap(annotation: Any) -> tuple[Any, str]:
    """Annotated[X, Field(description=d)] -> (X, d)."""
    if get_origin(annotation) is Annotated:
        base, *extra = get_args(annotation)
        desc = next((m.description for m in extra if getattr(m, "description", None)), "")
        return base, desc or ""
    return annotation, ""


def _strip_none(annotation: Any) -> Any:
    """X | None -> X."""
    args = [a for a in get_args(annotation) if a is not type(None)]
    return args[0] if args and type(None) in get_args(annotation) else annotation


def _kind(annotation: Any) -> tuple[type | None, tuple[str, ...] | None]:
    if get_origin(annotation) is Literal:
        return str, tuple(get_args(annotation))
    origin = get_origin(annotation) or annotation
    return (origin, None) if origin in (int, float, bool, str, dict) else (None, None)


def params(fn: Callable[..., Any]) -> list[Param]:
    out = []
    hints = inspect.get_annotations(fn, eval_str=True)
    for name, p in inspect.signature(fn).parameters.items():
        base, desc = _unwrap(hints.get(name, Any))
        kind, choices = _kind(_strip_none(base))
        required = p.default is inspect.Parameter.empty
        out.append(Param(name, kind, choices, desc, required, None if required else p.default))
    return out

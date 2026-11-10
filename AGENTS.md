# Agent guide: gGest business data

Read-only toolkit over a gGest (Golfinho Software) ERP database exported to SQLite. Use it to answer any business
question: sales, margin, customers, quotes, repairs, warranty, stock, purchasing, receivables, payables, VAT, team.

## Golden rules
1. **Read-only.** Never write to gGest files or `data/`. The only writes are `build-views` / `refresh` when the
   user asks for a refresh or setup.
2. Start with the skill `.claude/skills/ggest-analyst/SKILL.md`, then the task skill that matches (table below).
3. Tool order: named tool (`uv run ggest list`) → saved query (`uv run ggest saved_queries --search "<words>"`) →
   read-only SQL on the business views (`uv run ggest query --sql ...`). Read `uv run ggest data_dictionary` (and
   `--topic <domain>`) before writing SQL.
4. "Today" = the data date (last document in the snapshot), shown by `management_kpi_snapshot`.
5. Money is EUR net of VAT; credit notes negative; cancelled/internal documents excluded. Margin is an estimate.
6. Never output credentials, raw repair-fault text in bulk, or customer contact lists unless asked for one customer.

## Interfaces
- CLI: `uv run ggest [--db <path>] <tool> [--param v] [--json]`. `--params` accepts JSON or `key=value,key=value`.
- MCP: `uv run ggest-mcp [--db <path>]` (FastMCP, stdio) exposes the same tools, all marked read-only. Tables
  come back as `{columns, rows}` (names once, not per row); `truncated: true` means cut at `limit`.
- Context budget: `saved_queries` lists one line per query, so search or filter by domain first; `--name`
  gives one query in full. Results default to 100 rows (`run_saved_query`) / 200 (`query`); ask for totals with
  a summary query rather than raising limits to thousands of rows.
- Date words in any date/year parameter: `today`, `year_start`, `this_year`, `last_year`, `last_year_start`,
  `last_year_end`, `today_last_year`, `today_mmdd`, `years_ago_3`.

## Skills (`.claude/skills/<name>/SKILL.md`)
| Area | Skills |
|---|---|
| Any question | `ggest-analyst` |
| Management | `business-review`, `sales-report`, `month-close` |
| Sales & products | `quote-followup`, `product-lookup`, `pricing-review` |
| Customers | `customer-briefing`, `winback-campaign`, `customer-segments`, `customer-data-cleanup` |
| Repairs | `repair-desk`, `device-history`, `warranty-check`, `repair-quality` |
| Finance | `collections`, `payables-and-cash`, `recurring-contracts`, `tax-calendar` |
| Stock & purchasing | `reorder-suggestions`, `stock-cleanup`, `stock-check`, `supplier-review` |
| Operations | `team-activity` |
| Data | `data-refresh`, `new-database-setup` |

## Library
23 named tools and 139 saved queries (`bi/queries/<domain>/`: sales 26, customers 27, repairs 23, finance 29,
stock 21, operations 5, management 5, setup 3). `uv run ggest check-queries` runs them all.
Start "why did sales change" questions with `management_change_drivers` (by series group, segment, product group,
ticket size, customer).

## Extending (developers and agents)
- New question → a `.sql` file in `bi/queries/<domain>/` with `-- name:`, `-- description:` (what it answers,
  columns, caveats; agents pick queries from this text), `-- params:` using date words. It becomes a tool.
- New view → `bi/sql/ext/<domain>.sql` (`DROP VIEW IF EXISTS x; CREATE VIEW x AS ...`), apply with
  `uv run ggest build-views --file bi/sql/ext/<domain>.sql`; document it in `docs/domains/<domain>.md`.
- New skill → `.claude/skills/<name>/SKILL.md` (frontmatter `name`, `description` with when-to-use phrases; steps
  with exact commands; output format). Test every command.
- New tool → a typed function in `bi/metrics/<domain>.py` decorated with `@tool("...")`: the signature is the
  contract (`Literal[...]` = allowed values, `DateArg`/`Annotated[..., Field(description=...)]` documents a
  parameter). The CLI command and the MCP tool are generated from it. Add a test in `tests/bi/`.
- Company-specific rules go in `ggest.json` (see `bi/config.example.json`), never hard-coded.
- Public repo: no customer/staff names, NIFs, contacts or business figures in code, queries, skills or docs.

## Development
`uv sync` installs everything (Python 3.12+, click, FastMCP; dev: pytest, ruff, radon). Before a change is done:
```
uv run ruff check . && uv run ruff format --check .
uv run pytest --cov --cov-report=json        # tests use a synthetic database; `livedb` tests need data/data.sqlite
uv run python scripts/crap.py --max 30       # CRAP = complexity² × (1 − coverage)³ + complexity, per function
```

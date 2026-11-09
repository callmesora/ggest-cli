# ggest-cli

Read-only data tools for **gGest** (Golfinho Software's WinDev / HFSQL Classic ERP), without the original
analysis file (`.wdd`): export the `.fic` tables to SQLite, then query them through business views, a CLI,
54 saved queries and an MCP server for AI agents.

```
pipeline/     .fic/.ndx/.mmo  ->  XML (WDMap on a hidden desktop)  ->  data/data.sqlite (+ memo files)
bi/           business views (sql/semantic.sql), metrics, CLI, MCP server, saved queries (queries/)
dashboards/   scripts that turn the database into JSON datasets for a dashboard
docs/         DATA_DICTIONARY.md: views, definitions, caveats
```

Requirements: Windows, Python 3.12+ (`py`), standard library only. For exporting: WDMap from
WINDEV 28 (the free Express edition works, no activation needed).
Nothing ever writes to the gGest files: the pipeline copies them first.

## 1. Build the database

```bash
py pipeline/refresh.py --source "<gGest data folder with the .fic files>"
```

Copies the folder, exports every table with WDMap on a hidden desktop (nothing to click, ~25 min,
4 workers, failed tables retried), builds `data/data.sqlite` with the business views and extracts memo
attachments to `data/memo_files/`. The new database replaces the old one only once it is complete.

Options: `--workers N`, `--tables a,b` (quick test), `--out <folder>`, `--skip-dashboard`, `--keep-work`.

## 2. Ask questions (CLI)

```bash
py -m bi list                                    # every tool and its parameters
py -m bi kpis --start 2025-01-01 --end 2025-12-31
py -m bi year_over_year
py -m bi top_products --by margin --limit 15
py -m bi top_customers --limit 20
py -m bi customer_profile --query "<part of a name>"
py -m bi repairs_breakdown --by equipment --start 2024-01-01
py -m bi saved_queries                           # the library in bi/queries/
py -m bi run_saved_query --name finance_receivables_aging
py -m bi query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
```

Add `--json` for machine-readable output. `query` accepts one SELECT/WITH only, and password columns are blocked.

## 3. Use it from an AI agent (MCP)

`py -m bi.mcp_server` is a dependency-free, read-only stdio MCP server exposing the same tools.

- Claude Code: open this folder; `.mcp.json` registers it. Or run `claude mcp add ggest -- py -m bi.mcp_server`.
- Other clients: command `py`, args `["-m", "bi.mcp_server"]`, working directory = this folder.

Agents should call `data_dictionary` first, prefer the named tools and saved queries, and use `query` for the rest.

## 4. Add a saved query

Drop a `.sql` file in `bi/queries/<area>/`; it becomes a tool automatically:

```sql
-- name: sales_by_brand
-- description: Net sales and margin per brand.
-- params: start=2024-01-01, limit=20
SELECT brand_name, ROUND(SUM(net),0) AS net, ROUND(SUM(margin),0) AS margin
FROM sales_facts WHERE doc_date >= :start GROUP BY 1 ORDER BY 2 DESC LIMIT :limit
```

## Definitions

Money is EUR net of VAT; credit notes count negative; cancelled documents, internal consumption and sponsorships
are excluded. Gross margin = net − cost at average cost price (labour has no recorded cost; products without a cost
get an estimate from their family's ratio). Full list and pitfalls: [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md).

## Privacy

`data/` holds the whole business (customers, tax numbers, repair notes, credentials stored by gGest) and is
git-ignored. Keep it, the dashboard datasets and any reports out of this repository.

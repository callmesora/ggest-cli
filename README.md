# ggest-cli

Read-only business toolkit for **gGest** (Golfinho Software's WinDev / HFSQL ERP), built for AI agents and people:
export a gGest database to SQLite without the `.wdd` analysis file, then answer business questions through
business views, a CLI, 139 documented saved queries, 26 agent skills and an MCP server.

```
pipeline/          .fic/.ndx/.mmo -> SQLite. Native reader (learned layouts) or WDMap on a hidden desktop
bi/                views (sql/), tools (metrics.py), saved queries (queries/<domain>/), CLI, MCP server, config
.claude/skills/    agent skills: business review, customer briefing, collections, repair desk, reorder, ...
docs/              DATA_DICTIONARY.md + domains/<domain>.md (tables, codes, traps)
AGENTS.md          start here if you are an agent
```

Requirements: Windows, Python 3.12+ (`py`), standard library only. WDMap (WINDEV 28, free Express edition, no
activation) is needed only for the first export and for tables the native reader does not know.
Nothing writes to gGest: the pipeline copies the files first.

## 1. Build the database

```bash
py pipeline/refresh.py --source "<gGest data folder>" --reader native
```

Copies the folder, reads every table (native reader: ~2 min; tables without a validated layout fall back to WDMap
and are learned from it), builds `data/data.sqlite` with the business views and extracts memo attachments. The
new database replaces the old one only when complete. `--reader wdmap` (default) exports everything with WDMap
(~25 min). Other options: `--out <folder>` (another database), `--workers N`, `--tables a,b`, `--keep-work`.

## 2. Configure what is company-specific (once per database)

Copy `bi/config.example.json` to `ggest.json` next to `data.sqlite`: internal document types, invoice series that
are a business unit (e.g. a franchise corner) or not trading revenue, expense categories, regions. Then
`py -m bi build-views`. The `new-database-setup` skill walks an agent through it with the `setup_*` queries.

## 3. Ask

```bash
py -m bi run_saved_query --name management_kpi_snapshot     # the business at a glance + data date
py -m bi run_saved_query --name management_change_drivers --params dim=segment
py -m bi year_over_year
py -m bi top_customers --start year_start --segment empresa
py -m bi saved_queries --search "warranty"                  # find a saved query
py -m bi query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
py -m bi --db D:/other/data.sqlite kpis                     # another gGest database
```

`py -m bi list` shows every tool; `--json` for machine-readable output; `--params` takes JSON or `k=v,k=v`.
Date words work in any date parameter: `today` (= last document date in the data), `year_start`,
`today_last_year`, `this_year`, `last_year`, ... `py -m bi check-queries` runs the whole library.

## 4. Agents

- **Claude Code**: open this folder. `CLAUDE.md`/`AGENTS.md` and the skills in `.claude/skills/` load automatically,
  and `.mcp.json` registers the MCP server.
- **Any MCP client**: command `py`, args `["-m", "bi.mcp_server", "--db", "<path>/data.sqlite"]`, cwd = this folder.
  One server entry per database.
- **Other agents**: point them at `AGENTS.md`; the skills are plain Markdown recipes of CLI commands.

All tools are read-only: `query` accepts one SELECT, and credential tables/columns that gGest stores in clear
(user passwords, e-mail/web-shop passwords, tokens, bank numbers) are refused. Repair free text is never returned
in bulk.

## Extend

A `.sql` file with a `-- name / -- description / -- params` header in `bi/queries/<domain>/` becomes a tool; a view
goes in `bi/sql/ext/<domain>.sql`; a skill in `.claude/skills/<name>/SKILL.md`. Details in `AGENTS.md`.

## Native reader (how it works)

HFSQL Classic records sit at a fixed stride after a scrambled description block. The reader frames records
from the file's control block, and decodes columns with per-table layouts (`pipeline/layouts/ggest_layouts.json`)
learned by matching raw bytes against a WDMap export (`fic_layout.py`). `validate_reader.py` checks every
table row by row against WDMap (253 of 257 non-empty tables exact on the reference database; the rest fall back
to WDMap). A table whose structure fingerprint changes after a gGest update falls back to WDMap and is re-learned.

## Privacy

`data/` holds the whole business (customers, tax numbers, repair notes, credentials stored by gGest) and is
git-ignored, as are `ggest.json`, dashboard datasets and reports. Keep them out of this repository.

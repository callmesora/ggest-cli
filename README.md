# ggest-cli

Ask business questions about a company that runs **gGest** (Golfinho Software's ERP, built on WinDev / HFSQL):
sales, margin, customers, quotes, repairs, stock, purchasing, receivables, payables, VAT. The toolkit copies the
gGest data into a SQLite file (no `.wdd` analysis file needed), adds business views on top, and answers through a
command line, an MCP server for AI agents, and a chat app for people. Everything is **read-only**: nothing is ever
written to gGest.

## How it works

```
gGest data folder (.fic/.ndx/.mmo)
        │  pipeline/refresh.py: copies the folder, reads every table (native reader, or WDMap as fallback)
        ▼
data/data.sqlite      raw gGest tables + business views (bi/sql) + company settings (ggest.json)
        │
        │  bi/: 23 typed tools + 139 documented saved queries (bi/queries/<domain>/*.sql)
        ├──▶ CLI            uv run ggest …        people, scripts, agents in a terminal
        ├──▶ MCP server     uv run ggest-mcp      Claude Code, Claude Desktop, any MCP client
        └──▶ Chat app       uv run ggest-app      people, in the browser (OpenRouter models)

.claude/skills/   26 step-by-step recipes for agents (business review, collections, repair desk, reorder, ...)
```

- **Business views** turn gGest's tables into readable ones: `sales_facts` (one row per sales line with cost and
  margin), `customers`, `customer_dim`, `repairs`, `receivable_docs`, `stock_items`, ...
  `docs/DATA_DICTIONARY.md` defines every column and rule: money net of VAT, credit notes negative, cancelled and
  internal documents excluded.
- **Company settings** (`ggest.json`, one per database) hold what differs between companies: internal document
  types, invoice series that are a business unit, service items, expense categories, customer regions.
- **One tool definition** feeds the CLI, the MCP server and the chat app. A tool is a typed Python function, and
  its signature is the schema.
- **Safety:** the SQL tool accepts one SELECT only. Credential tables and columns that gGest stores in clear are
  refused (passwords, tokens, bank numbers), and repair notes are never returned in bulk.

## Quick start (Windows)

**1. Install** [uv](https://docs.astral.sh/uv/) and the project. uv installs Python 3.12+ and every dependency. Open
a new terminal after installing uv so it is on your PATH.

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
git clone https://github.com/callmesora/ggest-cli.git
cd ggest-cli
uv sync
```

**2. Build the database** from a gGest data folder (a network share is fine; it is only read):

```powershell
uv run python pipeline/refresh.py --source "\\SERVER\gGest\Dados" --reader native
```

It copies the folder, reads every table, builds `data/data.sqlite` with the views, and replaces the old database
only when the new one is complete. Reading takes a few minutes; building the database can take 10–15 minutes on a
large company. **WDMap** (free WINDEV Express edition) is required with both readers: the native reader hands it
the few tables it does not recognise (the log lists them; "keep using WDMap" there is normal). It is expected at
`C:\PC SOFT\WINDEV 28 Express\Programs\WDMAP.exe`; set the `WDMAP` environment variable if it lives elsewhere.
Useful options:

- `--reader wdmap` exports everything with WDMap (about 25 minutes).
- `--out <folder>` builds the database in another folder (e.g. for another company; see "Several companies").
- `--tables a,b` exports only those tables, for quick tests.

**3. Configure it once per database (optional at first).** The defaults (`bi/config.default.json`) work for any
gGest company. Company rules go in a `ggest.json` **next to the database** (`data/ggest.json`, or `<out>\ggest.json`).
Start with `{}` and add only keys you know apply: `bi/config.example.json` documents each one with made-up values,
so don't copy it as is. Then run `uv run ggest build-views`. The `new-database-setup` skill walks an agent through
this with the `setup_sales_doc_types`, `setup_invoice_series` and `setup_expense_creditors` queries.

**4. Ask.** Use any of the three ways below.

## Use it

**Command line**

```powershell
uv run ggest run_saved_query --name management_kpi_snapshot      # the business at a glance + the data date
uv run ggest year_over_year
uv run ggest top_customers --start year_start --limit 10
uv run ggest run_saved_query --name management_change_drivers --params dim=segment
uv run ggest saved_queries --search "warranty"                   # find a saved query (one line each)
uv run ggest query --sql "SELECT year, SUM(net) FROM sales_facts GROUP BY 1"
```

- `uv run ggest list` shows every tool, and `--help` works on any of them.
- `--json` gives machine-readable output. `--params` takes JSON or `k=v,k=v`.
- Dates accept words: `today` (the last document date in the data), `year_start`, `today_last_year`,
  `last_year`, ...
- Long results come in pages; the output says which `--offset` gives the next page.
- Commands use `data/data.sqlite`. For a database built elsewhere add `--db <folder>\data.sqlite` or set the
  `GGEST_DB` environment variable.

**Chat app**

```powershell
uv run ggest-app          # opens http://127.0.0.1:8765
```

A desktop-style chat in the browser:

- **Projects** in a sidebar, one per gGest database, each holding its chats.
- **Answers** stream in, with the tool steps the assistant took.
- **Inline widgets:** KPI cards, charts, tables, callouts and clickable follow-up questions.

On first start, paste an [OpenRouter](https://openrouter.ai/keys) key and pick a model. The app opens with a project
for `data/data.sqlite`; add more with **+** next to *Projects* (name and database file). `--port` and `--no-browser`
are available. The default is DeepSeek V4.1
Flash; the list has other low-cost models and Claude, and Settings accepts any OpenRouter model id. The key and the
chats stay on this computer (`data/assistant.sqlite`), and the app only listens on localhost. The system prompt and
widget examples are in `assistant/prompts.py`.

**AI agents**

- **Claude Code:** open this folder. `CLAUDE.md`, `AGENTS.md`, the skills and the MCP server (`.mcp.json`) load
  automatically.
- **Any MCP client:** add a server with command `uv` and args
  `["run", "--directory", "<this folder>", "ggest-mcp", "--db", "<path>/data.sqlite"]`.
- **Other agents:** point them at `AGENTS.md`. The skills are plain Markdown recipes of CLI commands.

## Several companies

Build one SQLite file per gGest database (`--out D:\gGest\CompanyB`), with its own `ggest.json` next to it. Then
reach it from any interface:

- **CLI:** add `--db D:\gGest\CompanyB\data.sqlite`.
- **MCP:** register one server entry per database.
- **Chat app:** add one project per database (**+** next to *Projects*).

## Layout

```
pipeline/       gGest files → SQLite: native .fic reader + learned layouts, WDMap fallback, memo extraction
bi/             views (sql/), tools (metrics/), saved queries (queries/), CLI, MCP server, settings (config*.json)
assistant/      chat app: Starlette server, agent loop, OpenRouter client, prompt, UI (static/)
dashboards/     optional: exports JSON datasets for a dashboard page
.claude/skills/ agent skills          docs/  data dictionary + per-domain notes (tables, codes, traps)
tests/          pytest on synthetic data (+ `livedb` checks when data/data.sqlite exists)
scripts/        crap.py (complexity × coverage per function)
```

## Extend

- **New question:** add a `.sql` file in `bi/queries/<domain>/` with `-- name`, `-- description` and `-- params`
  headers. It becomes a saved query.
- **New tool:** write a typed function with `@tool` in `bi/metrics/`. It becomes a CLI command, an MCP tool and a
  chat-app tool.
- **New view:** add it to `bi/sql/ext/<domain>.sql`.
- **New skill:** add `.claude/skills/<name>/SKILL.md`.

Conventions are in `AGENTS.md`.

## Develop

```powershell
uv run ruff check . ; uv run ruff format --check .
uv run pytest --cov --cov-report=json
uv run python scripts/crap.py --max 30
```

Tests run on a synthetic database. The `livedb` tests also run when `data/data.sqlite` exists (or `GGEST_DB` points to
a database); otherwise they are skipped.

## Native reader

HFSQL Classic files store records at a fixed stride after a scrambled header:

- **Reading:** the reader finds the records from the file's control block, then decodes each column with a per-table
  layout (`pipeline/layouts/ggest_layouts.json`).
- **Learning a layout:** `fic_layout.py` matches the raw bytes against a WDMap export.
- **Checking:** `validate_reader.py` compares every table row by row with WDMap. On the reference database, 253 of
  257 non-empty tables match exactly; the other four are read through WDMap.
- **After a gGest update:** a table whose structure changed falls back to WDMap and is learned again.

## Privacy

`data/` holds the whole business: customers, tax numbers, repair notes, and credentials stored by gGest. It is
git-ignored, and so are `ggest.json`, dashboard datasets and reports. Keep them out of the repository.

---
name: ggest-analyst
description: How to answer any business question from a gGest (Golfinho Software) database with the bi toolkit — sales, margin, customers, products, repairs, stock, receivables, expenses. Use it first whenever the user asks about the business data ("quanto vendemos", "quem nos deve", "how are sales", "top clientes", "margem", "assistências").
---
# Answering business questions from gGest

Run everything from the project root. Read-only: nothing here can change gGest.

## 1. Orient (once per session)
- `uv run ggest run_saved_query --name management_kpi_snapshot` — the business at a glance and the **data date**
  (the snapshot's last document date; "today" in every query means this date, not the calendar date).
- `uv run ggest data_dictionary` (rules and caveats) and `uv run ggest data_dictionary --topic <domain>` (tables, codes
  and traps of sales, customers, repairs, finance, stock, operations) before writing SQL.

## 2. Pick the tool, in this order
1. A named tool: `uv run ggest list` (kpis, year_over_year, top_products, top_customers, customer_profile,
   product_profile, repairs_breakdown, ...). Add `--json` when you will post-process.
2. A saved query: `uv run ggest saved_queries --search "<words>"` (or `--domain sales|customers|repairs|finance|stock|operations|management|setup`),
   then `uv run ggest run_saved_query --name <name> --params '{"start": "2024-01-01"}'`. Read the description: it
   states the rules and caveats of the numbers.
3. Ad-hoc SQL on the business views: `uv run ggest query --sql "SELECT ..."` (one SELECT/WITH, 200-row cap).
   `uv run ggest describe --name <view or table>` lists columns. Prefer views (sales_facts, sales_docs, customers,
   items, repairs, purchase_docs, ...) over raw gGest tables.
4. A domain skill when the task matches one (customer briefing, collections, repair desk, reorder, ...).

## 3. Rules for correct numbers
- Money is EUR **net of VAT** unless a column says gross. Credit notes are negative; cancelled documents and
  internal ones (internal consumption, sponsorship, non-trading series from the config) are excluded.
- Margin = net − cost at average cost price. Labour/services have no recorded cost. Some products have an
  estimated cost (`cost_estimated`) — say so when margin matters.
- Compare like with like: year-to-date vs the same days last year (`today_last_year`), never a partial year vs a
  full one.
- Company-specific meaning (series groups, expense categories, regions) comes from `ggest.json` next to the
  database (see `bi/config.example.json`); `setup_*` queries show what it currently does.

## 4. Answer
- Lead with the answer and the number, then 3–6 supporting lines or a small table. State the period and the
  data date. Use the user's language (Portuguese by default), € with thousands separators.
- Mention caveats only when they change the reading (estimated costs, open year, missing data).
- Never quote passwords or free-text repair notes in bulk (they can hold customer passwords); never list
  personal contact data unless the user asks for one specific customer.

## Several databases
One SQLite file per gGest database: `uv run ggest --db <path>/data.sqlite <tool> ...` (MCP: `uv run ggest-mcp --db <path>`).

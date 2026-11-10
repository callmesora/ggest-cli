---
name: new-database-setup
description: Bring another gGest database into the toolkit — export it to SQLite, review its company-specific settings (internal document types, special invoice series, expense categories, regions) in ggest.json and check the numbers. Use when the user adds a new company/database or says the numbers of a database look wrong ("nova base de dados", "outra empresa", "configurar", "set up database").
---
# Set up a new gGest database

## 1. Export (read-only, no clicking)
`uv run python pipeline/refresh.py --source "<gGest data folder with .fic files>" --out "<folder for this database>" --skip-dashboard`
→ `<folder>/data.sqlite`. Use `--db "<folder>/data.sqlite"` on every command below.

## 2. Inspect what is company-specific
- `uv run ggest --db <db> run_saved_query --name setup_sales_doc_types` — document types created by the company for
  internal consumption, sponsorship or asset sales (descriptions like "consumo interno", "patrocínio",
  "viaturas") must not count as sales → `internal_doc_types`. Types whose description contains
  "consumo interno" / "patroc" are already excluded by default.
- `uv run ggest --db <db> run_saved_query --name setup_invoice_series` — series with an odd pattern (very low
  margin, few big documents, a prefix used every year such as `CHIP22, CHIP23`) are a separate business unit
  (`series_groups`) or not trading at all (`excluded_series_prefixes`, e.g. selling a company car).
- `uv run ggest --db <db> run_saved_query --name setup_expense_creditors` — biggest creditors and the category they
  get; add `expense_rules` (by creditor code, name or text) until the top ~30 by value are classified.
- Customer regions: `uv run ggest --db <db> run_saved_query --name customers_geography --params level=region`.
  Defaults split Portugal into Continente / Madeira / Açores by postcode. If the company's market is one
  island, district or set of towns, add `regions` (postcode ranges, address words) and finer `areas`
  (postcode ranges, address words, or `postal_names` from gGest's `codpostal`) so the top ~90% of sales
  land in a meaningful region; check `level=area` afterwards.
Ask the user to confirm anything that is a business judgement (is this series a separate unit?).

## 3. Write the config
Copy `bi/config.example.json` to `<folder>/ggest.json` (next to data.sqlite), keep only the keys you change,
then `uv run ggest --db <db> build-views` (rebuilds the views with the settings; takes 1–3 minutes).

## 4. Check
- `uv run ggest --db <db> check-queries` — every saved query must run.
- `uv run ggest --db <db> year_over_year` — compare yearly net sales with the company's accounts or gGest's own
  sales map; differences usually mean a missing internal type or series.
- `uv run ggest --db <db> run_saved_query --name sales_data_quality_by_year` — share of generic items and estimated
  costs (high values = weak margin figures).

## 5. Register it for agents
Add an MCP entry per database, e.g. in `.mcp.json`:
`"ggest-<company>": {"command": "uv", "args": ["run", "--directory", "<toolkit folder>", "ggest-mcp", "--db", "<folder>/data.sqlite"]}`

# Saved queries

One `.sql` file per question, grouped by domain folder (`sales/`, `customers/`, `repairs/`, `purchases/`, `finance/`).
Header comments `-- name:`, `-- description:`, `-- params: key=default, ...` then one SELECT/WITH using `:key`
placeholders. They become tools automatically (`uv run ggest saved_queries`, `uv run ggest run_saved_query --name X`).
Query the business views (see `docs/DATA_DICTIONARY.md`).

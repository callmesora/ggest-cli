---
name: sales-report
description: Period sales report vs the same period last year — totals, margin, what moved (business lines, customer segments, big deals, months) and why. Use for "como estão as vendas", "relatório de vendas do mês/ano", "comparar com o ano passado", "porque caíram as vendas", "sales report", "year to date vs last year".
---
# Sales report: period vs same period last year

Run from the project root (bash quoting shown; in Windows PowerShell 5.1 escape inner quotes as `\"`).
Dates: saved queries (`run_saved_query`) accept ISO `YYYY-MM-DD` or date words (`year_start`, `today`,
`last_year_start`, `today_last_year`...); named tools (`sales_over_time`, `top_products`...) need ISO dates.
"today" = last document date in the data, not the calendar date — say it in the report.

## Steps
1. Headline, period vs same days one year earlier (default: year to date):
   `uv run ggest run_saved_query --name sales_period_vs_last_year --params '{"start": "year_start", "end": "today"}'`
   → net sales, margin, margin %, invoices, customers, avg/median invoice, products/services, big documents
   (>= 5 000 €) and sales without them. For a month: `{"start": "2026-10-01", "end": "2026-10-31"}`.
2. Where the difference comes from:
   - Business lines: `uv run ggest run_saved_query --name sales_period_comparison_by_line --params '{"a_start": "last_year_start", "a_end": "today_last_year", "b_start": "year_start", "b_end": "today"}'` (A = previous, B = current).
   - Customer segments (customer_dim.segment), same days each year: `uv run ggest run_saved_query --name sales_customer_segments_by_year --params "start_year=last_year,through_mmdd=today_mmdd"`
     (one row per year and segment, with share of the year).
   - Series groups (e.g. franchise series vs shop): `uv run ggest run_saved_query --name sales_series_groups_by_year`.
   - Big deals in both periods: `uv run ggest run_saved_query --name sales_big_deals --params '{"start": "last_year_start", "min_net": 5000}'`.
   - Months: `uv run ggest sales_over_time --period month --start 2025-01-01 --end 2026-11-07`.
3. Optional context: `uv run ggest top_products --start 2026-01-01 --end 2026-11-07 --by margin --limit 10`,
   `uv run ggest top_customers --start 2026-01-01 --end 2026-11-07 --limit 10`,
   seasonality (share of the year still to come): `uv run ggest run_saved_query --name sales_seasonality_by_month`.
4. Pipeline: open quotes that may still land this period:
   `uv run ggest run_saved_query --name sales_quotes_conversion_by_year --params '{"doc_type": "all"}'` (column net_open).

## Reading the numbers
- Net of VAT, credit notes negative, cancelled / internal / vehicle sales excluded.
- Separate one-off big documents from day-to-day retail: report the change "sem negócios grandes" too.
- Never compare a partial year with a full year; for a forecast use `management_year_end_forecast`.
- Margin is estimated (average cost); services have no cost, so mix shifts move margin %.
- A month with few working days or a late invoicing batch can swing ±20 %: check the months table.

## Output (Portuguese by default)
**Vendas <período> vs <período ano anterior>** (dados até <today>)
| Indicador | Atual | Ano anterior | Δ | Δ % |  ← vendas, margem, margem %, faturas, clientes, ticket médio
Then 3–5 bullets "O que explica a diferença" (largest line/segment/deal moves, in €), one line on big deals,
one line on what is still open (quotes), and at most one caveat. Euros with thousands separators, 1 decimal %.

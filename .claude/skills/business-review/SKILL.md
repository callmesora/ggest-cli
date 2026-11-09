---
name: business-review
description: Monthly, quarterly or year-to-date business review of a gGest company — sales and margin vs last year, what drove the change (business lines, customers, products), repairs, receivables, overheads and the year-end outlook. Use for "como está o negócio", "resumo do mês", "relatório mensal", "business review", "how did we do this month/quarter".
---
# Business review

Default period: year-to-date at the data date, plus the last complete month. Run from the project root.

## Steps
1. Headline: `py -m bi run_saved_query --name management_kpi_snapshot`
2. Month by month vs last year: `py -m bi run_saved_query --name management_monthly_scorecard`
3. What moved (same days both years by default) — run each dimension and keep the biggest `net_change` rows:
   `py -m bi run_saved_query --name management_change_drivers --params dim=series_group` then `dim=segment`,
   `dim=group`, `dim=ticket` (big one-off deals), `dim=customer`. `share_of_total_change_pct` says how much of
   the change each value explains. For a single month pass `a_start/a_end/b_start/b_end` (ISO dates).
   Business lines: `sales_period_comparison_by_line` with the same four dates.
4. Who and what: `py -m bi top_customers --start year_start --limit 10` and
   `py -m bi top_products --start year_start --by margin --limit 10`.
5. Business units on their own invoice series (if configured), like for like:
   `py -m bi run_saved_query --name sales_series_groups_by_year --params start_year=last_year,cutoff_mmdd=today_mmdd`
6. Repairs: `py -m bi repairs_over_time --period month --start <last_year_start>` and the open backlog
   `py -m bi run_saved_query --name repairs_open_backlog --params '{"min_age_days": 30}' --json` (count the rows; don't list them).
7. Cash: `py -m bi run_saved_query --name finance_receivables_aging`.
8. Costs (when the database records overheads as 'outros credores'):
   `py -m bi run_saved_query --name finance_operating_expenses_by_category`.
9. Outlook: `py -m bi run_saved_query --name management_year_end_forecast` (low/base/high from the share of sales
   that came after this date in the 3 previous years).

## Output (Portuguese by default, one page)
- **Em resumo**: 2–3 sentences with net sales, margin and change vs last year, and the main reason.
- Table: KPI | este ano | ano passado | Δ%.
- **O que mudou**: 3–5 bullets (lines, customers, months) with € amounts.
- **Atenção**: receivables > 90 days, old open repairs, margin pressure, data caveats.
- **Previsão**: base scenario and range, with the assumption.

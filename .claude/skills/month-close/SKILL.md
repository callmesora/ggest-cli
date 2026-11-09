---
name: month-close
description: Month-close pack from gGest — the month's sales, margin, overheads, indicative result, VAT, cash in/out, receivables and payables vs the previous month and the same month last year. Use for "fecho do mês", "fechar o mês", "resultados de outubro", "como correu o mês", "mapa mensal para a contabilidade", "month close", "monthly results", "month-end report".
---
# Month close (fecho do mês)

Run from the project root. For a closed month pass its **last day**; with the default (data date) the three
periods are month-to-date, cut at the same day of the month (like-for-like).

## Steps
1. The pack: `py -m bi run_saved_query --name finance_month_close --params '{"as_of":"2026-10-31"}'`
   Rows: net_sales, gross_margin(_pct), invoices, purchases_net, overheads_staff/rent/other/total,
   operating_result_indicative, investments_not_deducted, vat_output/input/net, money_in/out, receivables_end,
   receivables_overdue_90d_end, payables_end. Columns: this_month, previous_month, same_month_last_year,
   vs_prev, vs_last_year and change_unit (% for amounts, **pp** for gross_margin_pct).
   Balances are at the end of each period: for a closed month they differ from `finance_receivables_aging`
   (balance today); say which date each figure refers to.
2. Year context: `py -m bi run_saved_query --name finance_profit_and_loss_by_year --params '{"cutoff_mmdd":"10-31"}'`
   (year-to-date to the same day each year; `period` says full/partial; for partial rows use
   `break_even_annualized`, never `break_even_sales`, against a full-year forecast) and
   `py -m bi run_saved_query --name management_monthly_scorecard` (each month vs last year).
3. Explain a big change in overheads:
   `py -m bi run_saved_query --name finance_operating_expenses_by_category --params '{"start_year":2026}'`;
   in sales: `py -m bi saved_queries --search "period_comparison"`.
4. Receivables, if they grew: `py -m bi run_saved_query --name finance_receivables_trend`.
5. VAT by rate for the month:
   `py -m bi run_saved_query --name finance_vat_by_period --params '{"start":"2026-10-01","end":"2026-10-31","granularity":"month"}'`.
6. Missing costs: overhead documents often arrive late (rent, payroll, forwarders). If overheads_total is far below
   a normal month, say the month may be incomplete. `py -m bi run_saved_query --name finance_efatura_unmatched`
   lists e-fatura invoices not registered in gGest (only for periods imported from e-fatura).

## Rules and traps
- Sales and margin are net of VAT; margin is an estimate (average cost). Services carry no labour cost: wages are overheads.
- Indicative result = gross margin − staff − rent − other overheads. Investments, loan instalments and taxes are NOT deducted.
- Yearly bills booked in one month (annual rent, insurance) distort a single month: always show year-to-date too.
- money_in/out are gross (with VAT); receivables/payables are balances at the period end, with VAT.
- Overheads exist only from the year the company started registering 'outros credores' documents in gGest.

## Output (Portuguese by default)
- **Em resumo** (3 sentences): vendas, margem, resultado indicativo do mês e comparação.
- Table: Indicador | Mês | Mês anterior | Mesmo mês ano passado | Δ% — grouped as Vendas, Custos, Resultado,
  IVA, Tesouraria, Saldos.
- **Atenção**: 2–4 bullets (overdue receivables growing, missing costs, VAT to pay, cash outflow peaks).

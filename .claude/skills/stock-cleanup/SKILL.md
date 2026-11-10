---
name: stock-cleanup
description: Dead and slow stock to clear — how much money is stuck, in which groups, which items, and what to do with each (return to supplier, use in repairs, promotion/bundle, write-off). Use for "stock parado", "stock morto", "o que não vende", "limpar o armazém", "promoções para escoar", "abates", "dead stock", "slow movers", "stock clearance", "inventory write-off".
---
# Stock clean-up (escoar stock parado)

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## Steps
1. Size of the problem per group and action (no sale in 12 months; items bought in the last 3 months ignored):
   `uv run ggest run_saved_query --name stock_cleanup_summary --params '{"months": 12}'`
2. Item list with the suggested action (biggest value first; filter a group with `"group": "CONSUM"`):
   `uv run ggest run_saved_query --name stock_cleanup_candidates --params '{"months": 12, "min_value": 20, "limit": 40}'`
3. Context: which groups hold more stock than they sell, and the trend of the stock value:
   `uv run ggest run_saved_query --name stock_turnover_by_group`
   `uv run ggest run_saved_query --name stock_value_by_year`
4. Finance's view (counts purchases as activity too, months without ANY movement):
   `uv run ggest run_saved_query --name finance_stock_value_by_group` and `finance_dead_stock_items`.
5. Data errors to fix first: `uv run ggest run_saved_query --name stock_negative_items`.

## Suggested actions (column `suggested_action`)
- `return_to_supplier` — bought in the last 12 months and not selling: ask the supplier for a return/credit
  (DEVNC); the sooner the better.
- `use_in_repairs` — spare parts (SPARES): use in repair jobs before buying new parts; write off what is obsolete.
- `promote_or_bundle` — sold before but idle: discount down to cost, add to PC bundles or campaigns to companies.
- `write_off_or_sell_at_cost` — never sold and older than 24 months, or idle > 36 months: clearance or abate
  (gGest document SSTKA "Saída de stock abate de mercadoria"; tell the accountant).
- Consumables (toners/ink) for printers nobody owns any more rarely sell: stop stocking toners with < 2 sales/year.

## Reading the numbers
- Only stocked goods: software/licences, hosting, services and freight are excluded. The summary's TOTAL row
  gives total stock value and the idle share of it.
- Value at cost = current average cost (pmc) × quantity; `months_idle` since the last sale (or purchase if never sold).
- Year-end values (`stock_value_by_year`) match the AT inventory communication; the last row is today's stock.

## Output (Portuguese by default)
Short brief: stock total, stock parado (valor e %), por grupo (top 5) and per action; then the top 15 items
(código, descrição, qtd, valor, última venda, ação sugerida, preço de saída sugerido = custo ou PVP −x %);
close with 3 concrete actions and the cash they would free.

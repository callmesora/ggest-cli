---
name: reorder-suggestions
description: Purchase list — what to order now: fast-moving items low on stock, how many to buy, from which supplier and at what last/cheapest cost. Use for "o que tenho de encomendar", "lista de compras", "o que está a acabar", "rutura de stock", "reposição de stock", "reorder", "what should I buy", "low stock", "purchase suggestions".
---
# Reorder suggestions (lista de encomendas)

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## Steps
1. Candidates (demand of the last 90 days = sales + components used in PC builds − returns; cover target 45 days):
   `uv run ggest run_saved_query --name stock_reorder_suggestions --params '{"days": 90, "target_days": 45, "min_out": 3, "limit": 40}'`
   - One group only: add `"group": "CONSUM"` (part of the group name: CONSUMÍVEIS, COMPONENTES, REDES…).
   - Slow season / big orders: raise `min_out`; fast-moving consumables: `"days": 60, "target_days": 30`.
   - **Purchase orders per supplier** (one row per supplier: items, units, total `order_value`, item list):
     `uv run ggest run_saved_query --name stock_reorder_suggestions --params '{"group_by": "supplier", "limit": 15}'`
2. For the top lines, check that the price did not jump (and who sells it cheaper):
   `uv run ggest run_saved_query --name stock_supplier_best_prices --params '{"months": 12, "limit": 30}'`
   and, for one item, `uv run ggest run_saved_query --name stock_item_purchase_history --params '{"item": "W1350A", "limit": 10}'`.
3. Recent price increases to pass on to selling prices (`direction` up/down/both; `group_by: supplier` for totals):
   `uv run ggest run_saved_query --name stock_supplier_price_changes --params '{"direction": "up", "limit": 15}'`
4. Before ordering a slow/expensive item, confirm the stock card (maybe a return or delivery note is pending):
   `uv run ggest run_saved_query --name stock_item_movements --params '{"item": "<code>", "limit": 15}'`

## Reading the numbers
- `units_out` counts every unit that left stock to customers or into assembled PCs; `customers` = distinct buyers.
  One customer buying 6 units once is a project, not steady demand: prefer items with several customers.
- `days_of_cover` 0 = already out of stock. `suggested_qty` = demand rate × target days − stock (rounded up);
  `order_value` = suggested_qty × last cost (last purchase invoice, net). `supplier` = last real supplier.
- `margin_pct` uses the catalogue price and the last cost; a blank/0 `price_net` means the price is set per sale.
- Costs are net of VAT and line discounts, without inbound freight (~3 % of goods, see
  `finance_freight_costs_by_year`): group orders by supplier to dilute freight.
- No supplier orders (NREQ) are recorded in gGest here, so "on order" is unknown — ask before duplicating an order.
- Non-stock items (software/licences, hosting, services, freight) are excluded: they are bought on demand.

## Output (Portuguese by default)
Table grouped **by supplier** (fornecedor → artigos): código, descrição, saídas 90 d, stock, cobertura (dias),
qtd sugerida, último custo, PVP s/IVA, margem. Then: estimated order value per supplier, items with a cheaper
supplier or a recent price increase, and 1–2 remarks (e.g. "monitor X: 6 unidades num só cliente — confirmar").

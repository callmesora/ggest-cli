---
name: product-lookup
description: Everything about one item (artigo) — price, cost, margin, stock, last sales and purchases (who, when, at what price), quotes, online-shop status. Use for "quanto custa X", "a quanto vendemos/comprámos o X", "temos X em stock", "ficha do artigo", "último preço de compra", "quem compra X", "price of", "item lookup", "last purchase price".
---
# Product lookup

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## Steps
1. Find the item and its profile (code, description, family, brand, price net, last purchase price and supplier,
   stock, sales and margin per year, top customers):
   `py -m bi product_profile --query "800 G3"` — if it returns `ambiguous`, pick the code (prefer the one with stock
   or recent sales) and run again with the exact code: `py -m bi product_profile --query ecopchp800g3mini`.
2. Latest movements (sales with customer/price/cost/margin, purchases with supplier/net unit price, quotes):
   `py -m bi run_saved_query --name sales_item_transactions --params '{"item_code": "ecopchp800g3mini", "limit": 30}'`
3. Is it on the web shop? `py -m bi query --sql "SELECT item_code, online_name, is_active, is_visible, synced_on FROM online_items WHERE item_code = 'ecopchp800g3mini'"`
4. Family-level context (refurbished, a model range, a brand) when the question is broader than one code:
   `py -m bi run_saved_query --name sales_item_search_by_year --params '{"pattern": "%800 g3%", "pattern2": ""}'`
   or `py -m bi sales_by_category --level brand --start 2025-01-01 --end 2026-11-07`.
5. Alternatives in stock (same family): `py -m bi query --sql "SELECT item_code, description, price_net, stock_qty FROM items WHERE family_name = 'MINI PC' AND stock_qty > 0 ORDER BY price_net"`.

## Reading the numbers
- `price_net` is the catalogue price **without VAT**; price with VAT = `price_gross` (Azores VAT, 16 % now).
- Margin at catalogue price = (price_net − last_purchase_price) / price_net. Sales-line cost is the average cost
  (pmc) at sale time; `cost_source` ≠ pmc means estimated.
- Items bought per box and sold per unit, or with an old corrupted average cost, show absurd margins: say so.
- The generic item `ZZ` (free text) has no catalogue data — search the description with step 4 instead.
- Stock is the gGest running stock; it can be off for items sold through ZZ or bundles.

## Output (Portuguese by default)
**<código> — <descrição>**: PVP s/IVA · c/IVA, último custo (fornecedor, data), margem ao PVP, stock.
Then "Últimas vendas" (3–5 rows: data, cliente, qtd, preço), "Últimas compras" (2–3 rows), sales last 12 months
and trend, web-shop status, and one recommendation if something is off (price below cost, no stock but active online).

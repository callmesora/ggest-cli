---
name: pricing-review
description: Margin and pricing check — items sold at low or negative margin, catalogue prices below cost, deep discounts given at the counter, discount totals, web-shop items without stock/price. Use for "rever preços", "artigos com margem baixa", "vendas abaixo do custo", "descontos", "preços desatualizados", "pricing review", "low margin", "below cost".
---
# Pricing and margin review

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## Steps
1. Sold at low/negative margin (period, product lines, ≥ min_net per item):
   `py -m bi run_saved_query --name sales_low_margin_items --params '{"start": "last_year_start", "max_margin_pct": 10, "min_net": 300}'`
2. Catalogue prices that no longer cover the last purchase price (items in stock or sold recently):
   `py -m bi run_saved_query --name sales_price_below_cost --params '{"min_margin_pct": 15}'`
3. Counter price cuts — lines sold ≥ 20 % under today's catalogue price or below cost, with the user who issued them:
   `py -m bi run_saved_query --name sales_discounted_lines --params '{"start": "year_start", "min_discount_pct": 20}'`
4. Explicit discount fields per year (usually small: most price cuts are typed into the unit price):
   `py -m bi run_saved_query --name sales_discounts_by_year`
5. Margin by family/brand to see where to act: `py -m bi sales_by_category --level family --start 2025-01-01 --end 2026-11-07`
   and margin data quality per year: `py -m bi run_saved_query --name sales_data_quality_by_year`.
6. Web shop: `py -m bi run_saved_query --name sales_online_catalog_check` (active items with no stock or price 0).

## Tell real under-pricing from data errors
- Margin −100 % to −400 % on cheap items = unit mismatch (bought per box, sold per unit) → fix the item's unit /
  purchase conversion, not the price.
- Hardware with > 60 % margin or a cost far below the last purchase = corrupted average cost (pmc).
- `cost_source` = `last_purchase` / `estimated` → cost is a fallback; check `sales_item_transactions` for the item.
- Domains/hosting and monthly software subscriptions carry an annual or fixed cost → margins look negative.
- Catalogue price is today's; a "discount" on an old sale may just be a later price rise.
- Some families (processors, graphics cards, some brands, franchise PCs) have structurally thin margins: compare
  with the family average (step 5) before calling a price wrong.

## Output (Portuguese by default)
Three short tables (max 10 rows each): **Preços a corrigir** (código, artigo, PVP s/IVA, último custo, margem %,
stock, sugestão de PVP for a target margin = custo / (1 − margem alvo)), **Vendas abaixo do custo / com grande
desconto** (doc, data, artigo, preço, custo, utilizador), **Erros de dados** (artigo, causa provável). End with
2–3 actions in priority order and the € impact when it can be computed.

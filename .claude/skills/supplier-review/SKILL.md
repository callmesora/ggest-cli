---
name: supplier-review
description: Supplier review — spend and share per supplier, concentration, what we buy from each, price increases, cheaper alternatives for the same item, credit notes/returns and warranty RMAs. Use before negotiating or choosing a supplier: "análise de fornecedores", "quanto compramos à X", "fornecedor mais barato", "aumentos de preço", "devoluções a fornecedores", "RMA", "supplier review", "supplier spend", "price increases", "vendor comparison".
---
# Supplier review (análise de fornecedores)

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## Steps
1. Scorecard for the period (spend, share, items, credited %, order frequency, RMAs):
   `py -m bi run_saved_query --name stock_supplier_scorecard --params '{"start": "last_year_start", "end": "today", "limit": 20}'`
2. Concentration over the years and origin (Portugal / EU / extra-EU) — finance queries:
   `py -m bi run_saved_query --name finance_top_suppliers` and `py -m bi run_saved_query --name finance_purchases_by_origin`
3. What we buy from one supplier (`supplier` = code from step 1 or part of the name; top items, cost, what sold, stock left):
   `py -m bi run_saved_query --name stock_supplier_items --params '{"supplier": "23", "start": "last_year_start", "limit": 25}'`
4. Prices: increases in the last 12 months vs the 12 before, and items bought cheaper elsewhere:
   `py -m bi run_saved_query --name stock_supplier_price_changes --params '{"group_by": "supplier", "limit": 15}'`
   (per supplier: items up/down, weighted %, extra € paid) then items: `{"direction": "up", "min_change_pct": 5, "limit": 25}`
   `py -m bi run_saved_query --name stock_supplier_best_prices --params '{"months": 12, "limit": 25}'`
5. Returns/warranty: `credited` in step 1 (supplier credit notes) and the RMA history
   `py -m bi run_saved_query --name stock_supplier_rmas`
6. Freight paid per year (Azores logistics): `py -m bi run_saved_query --name finance_freight_costs_by_year`

## Reading the numbers
- Money net of VAT; credit notes (DEVNC/VNC/VNCP/NCADI) are negative; intra-EU (FTINC) and extra-EU (FTEXC)
  invoices are purchases. Software/licence suppliers (e.g. the gGest vendor, cloud services) are resale costs too.
- `avg_days_between_invoices` is order frequency, NOT lead time: supplier orders are not recorded in gGest here,
  so delivery lead time cannot be measured.
- Big unit-cost jumps (> +150 %) are usually a change of unit (box vs unit) and are filtered out.
- Cheapest supplier comparisons ignore freight and timing (prices of memory/SSD rose in 2025-26): check dates.
- RMAs were registered only 2020-2024; later warranty returns appear only as supplier credit notes.

## Output (Portuguese by default)
Table of the top 10 suppliers (compras, quota, artigos, devoluções %, frequência), the share of the top 3,
then per supplier asked: top items and price trend; list of price increases worth passing to selling prices and
items to buy elsewhere (saving €); 2–3 negotiation points (volume, freight included, returns of idle stock).

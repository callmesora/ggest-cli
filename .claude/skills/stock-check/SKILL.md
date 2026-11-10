---
name: stock-check
description: Stock of an item right now and its stock card — quantity on hand/available/reserved, every entry and exit with running balance, serial numbers (when/from whom we bought it, to whom we sold it, warranty), negative stock and stock reconciliation. Use for "quantos temos de X", "stock do artigo", "onde foi parar o X", "ficha de stock", "movimentos do artigo", "número de série", "garantia do equipamento", "stock check", "kardex", "serial number lookup".
---
# Stock check (stock e movimentos de um artigo)

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).
There is a single warehouse in this gGest database. For prices/sales of the item use the `product-lookup` skill.

## Steps
1. Find the item and its stock (code, barcode or words of the description, all must match):
   `uv run ggest run_saved_query --name stock_item_lookup --params '{"search": "toner 415x"}'`
2. Stock card with running balance (newest first; `start` = first date to show):
   `uv run ggest run_saved_query --name stock_item_movements --params '{"item": "W2030X", "start": "2024-01-01", "limit": 30}'`
3. Serial number (warranty claim, stolen/returned equipment) — 3+ characters of the serial:
   `uv run ggest run_saved_query --name stock_serial_lookup --params '{"serial": "5CD21233ZX"}'`
   Serials sold in a period, by customer (code or name), item or part of the serial:
   `uv run ggest run_saved_query --name stock_serials_sold --params '{"customer": "2055", "start": "2024-01-01", "end": "2024-12-31"}'`
4. Stock that left without a sale this year (miscellaneous exits, write-offs, internal use):
   `uv run ggest run_saved_query --name stock_adjustments --params '{"start": "year_start", "end": "today"}'`
5. Data checks: negative stock `uv run ggest run_saved_query --name stock_negative_items`;
   card vs documents `uv run ggest run_saved_query --name stock_reconciliation_check` (first row = items checked / matching).

## Reading the numbers
- `qty_on_hand` = gGest real stock; `qty_available` = on hand − reserved − goods out on delivery notes (GTC not yet
  invoiced). Reservations/customer orders are barely used in this shop (usually 0).
- Movement kinds: sale / sale_return, purchase / purchase_return, assembly_out (component used in a PC build),
  assembly_in (built PC enters stock), adjustment_in/out (gGest ENTD/SAID "entradas/saídas diversas", no reason
  recorded), write_off (abate), internal_use, warranty_use, workshop_use, loan_out.
- `last_cost` = net unit cost on the last purchase INVOICE (`last_purchase_doc`); `cost_warning` =
  `pmc_vs_last_cost` when the average cost differs > 20 % from it (stale average: quote margins on both).
  `has_serials` = 1 → the item is serial-numbered (the serial in-stock flag in gGest is unreliable; trust qty).
- Serial history: `supplier` rows = our purchase (supplier warranty starts there); `customer` rows = sale, repair
  order (OSA) or quote; `is_cancelled` = 1 means that document was cancelled. `warranty_years` is the item's term.
- Opening balances come from gGest's year-closing (1 Jan); about 99.7 % of items reconcile exactly.
- Customer names appear in movements/serials: share them only with staff.

## Output (Portuguese by default)
**<código> — <descrição>**: stock atual (disponível), custo médio, valor; últimos 5–10 movimentos (data, documento,
tipo, entidade, qtd, saldo); for serials: comprado a <fornecedor> em <data>, vendido a <cliente> em <data>,
garantia até <data de venda + anos>. Flag anything odd (negative stock, exit without sale, mismatch).

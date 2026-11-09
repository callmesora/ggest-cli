---
name: warranty-check
description: Decide if a device or part is under warranty — sold by the shop when and to whom, warranty term and end date, whether the supplier warranty still allows an RMA, past repairs and RMAs; also the list of warranty jobs and of supplier RMAs still open. Use for "está na garantia?", "garantia do número de série", "posso mandar para RMA?", "RMAs em aberto", "warranty check", "is this under warranty".
---
# Warranty check (garantia e RMA)

Run from the project root.

1. **One serial**: `py -m bi run_saved_query --name repairs_warranty_check --params '{"serial":"<sn>"}'`
   - No rows → `"exact":0` with a fragment (≥ 5 chars), or look at the history: skill device-history.
   - To check at another date (e.g. the day the order was opened): `"as_of":"YYYY-MM-DD"`.
   - **Customer has no paperwork / serial unknown**: list what was sold to them with serial and warranty end:
     `py -m bi run_saved_query --name repairs_customer_devices --params '{"customer":"<code or name>"}'`; to search
     by item or period instead, use the stock query `stock_serials_sold` (`py -m bi saved_queries --search serial`).
2. **Context**: `py -m bi run_saved_query --name repairs_device_timeline --params '{"serial":"<sn>"}'`
   (earlier repairs of the same fault, previous RMAs, credit notes).
3. **Warranty jobs in a period** (orders on devices still under warranty when they came in):
   `py -m bi run_saved_query --name repairs_warranty_orders --params '{"start":"year_start"}'`
4. **Supplier RMAs** (gGest RMA module): `py -m bi run_saved_query --name repairs_supplier_rmas --params '{"status":"open"}'`
   and per supplier: `--params '{"grain":"supplier"}'`.

## Business rules and caveats
- Customer warranty = sale date + term. The term comes from the serial registry (`Artigos_series`:
  `Tipo_Garantia` 1 = years, 2 = months); when missing the query assumes 24 months (`term_source = assumido`).
  Portuguese law (DL 84/2021): 3 years for goods sold to consumers from 2022 (2 years before); businesses often
  get less — the gGest term may not reflect the legal one: if in doubt, say so.
- `sold_here = 0` → no sale of this serial in gGest: bought elsewhere (manufacturer warranty only), sold before 2017
  or serial typed differently. Ask for the invoice.
- `supplier_warranty_ok` is an approximation (purchase + same term). If 1, an RMA to `supplier_name` is possible;
  quote the purchase document `purchase_doc_id`.
- A sale later credited (`customer_return`) ends the warranty for that sale; the last valid sale counts.
- Physical/liquid damage and software issues are usually not covered — the decision is the technician's.
- Open RMAs from 2022–2024 with hundreds of `days_out` are almost certainly resolved but never closed in gGest.
- Never quote fault texts from orders or RMAs (passwords/PINs).

## Output (Portuguese by default)
Verdict first: **Em garantia até DD/MM/AAAA** (faltam N dias) / **Fora de garantia desde …** / **Sem venda registada**.
Then: artigo, vendido a (cliente, documento, data), comprado a (fornecedor, documento, data), RMA possível?,
reparações anteriores. For lists: table + totals.

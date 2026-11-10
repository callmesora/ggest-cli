---
name: device-history
description: Everything about one device or part by serial number — when it was bought from the supplier and sold, to whom, warranty, every repair order, parts fitted, supplier RMAs — or all serial-numbered equipment of one customer. Use for "histórico do equipamento", "número de série X", "este portátil já cá esteve?", "que equipamentos tem o cliente", "device history", "serial number lookup".
---
# Device history (histórico de um equipamento / número de série)

Run from the project root. `<sn>` = serial number as typed on the label or order (case does not matter).

1. **Timeline of the serial** (purchase, sale, credit notes, use as spare part, repair orders, RMAs):
   `uv run ggest run_saved_query --name repairs_device_timeline --params '{"serial":"<sn>"}'`
   - No rows → try a fragment: `"serial":"<part>","exact":0` (min 5 chars). Serials are often typed with or
     without dashes/prefixes (e.g. `S/N`, the product code + `/`).
   - Need the technician's notes for this device? add `"show_notes":1` (diagnosis and work done, 200 chars each).
2. **Warranty status** of the same serial (see skill warranty-check for details):
   `uv run ggest run_saved_query --name repairs_warranty_check --params '{"serial":"<sn>"}'`
3. **All serial-numbered items sold to a customer** (+ devices they only brought for repair), code or name fragment
   (accent-sensitive; a fragment matches every customer code with that name):
   `uv run ggest run_saved_query --name repairs_customer_devices --params '{"customer":"<code or name>"}'`
   `source=sold_here` = every serial on a valid (not cancelled, not credited) sale to that customer since 2017, with
   warranty end; then step 1 for the interesting serials. Items sold without a serial are not listed (see
   `customers_devices` for purchases by product family).

## Reading the results
- `event`: purchase (from supplier) · sale · customer_return (credit note) · supplier_return · repair_part (the serial
  was fitted/sold on a repair order — it is a part, not the device repaired) · repair_order (the device came in) ·
  supplier_rma_open/closed · loan · quote_or_order · delivery_note · internal_use · assembly.
- `detail` "documento anulado" = cancelled document (ignore); "linha creditada" = the sale was reversed.
- Serial tracking on sales starts in 2017 (repair-order parts 2008+). A device with only repair orders was bought
  elsewhere, before 2017, or its serial was typed differently.
- The customer on a repair order can differ from the buyer (family, company vs employee, duplicate records).
- `source=repaired_only` in customer devices: equipment the customer brings but did not buy here — sales opportunity
  when it is old or repeatedly repaired.
- Show notes only for the device asked about; never paste fault texts (customer passwords/PINs appear there).

## Output (Portuguese by default)
Short timeline table (data · evento · documento · cliente/fornecedor · detalhe), then 2–3 lines: comprado a quem e
quando, vendido a quem, garantia até, nº de reparações (e se é repetente: ≥ 3 reparações → sugerir substituição).

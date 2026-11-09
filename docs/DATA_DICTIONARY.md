# Inforbyte data dictionary

Data recovered from the **gGest** ERP (Golfinho Software, WinDev/HFSQL) used by Inforbyte — a computer shop in
Horta (Faial, Azores) that sells hardware, repairs equipment (*assistências*) and sells IT services/software.

- Database: `data/data.sqlite` (raw gGest tables, all values TEXT, exactly as exported) + **business views** below
  (`bi/sql/semantic.sql`). Query the views; use raw tables only for details the views lack.
- History: sales documents **2017-02 → 2026-11**; repair orders **2007 → 2026-11**; customers since 2007.
- Money: EUR, **net of VAT** unless a column says `gross`/`vat`. VAT rates seen on sales: 18% and 16% (Azores
  standard rate over time), 23% on mainland supplier invoices.
- Rules applied in the views: cancelled documents (`estado_doc = 1`, with `cancel_reason`) excluded from
  `sales_facts`; credit notes negative; internal consumption (`FRCIN`, `NCCIR`) and sponsorship (`FTPTC`)
  documents flagged `is_internal` and excluded from `sales_facts`; so are vehicle sales (doc type `VIAT`, series `VIA*`).

## Business views

### `sales_facts` — the main fact table (one row per sales line that counts)
Use for revenue, margin, products, customers. Columns:

| column | meaning |
|---|---|
| doc_id | `TYPE SERIES/NUMBER`, e.g. `FT 2025/1204` |
| doc_type, doc_class | gGest type (FT invoice, FR invoice-receipt, FS simplified, FTGOL, VIAT, NC/NCP credit notes); class `invoice` / `credit_note` |
| doc_date, year, quarter, month | document date (ISO), `2025`, `2025-Q4`, `2025-11` |
| customer_code, customer_name | customer (`customers.customer_code`); name as printed on the document |
| item_code, item_description | item (`items.item_code`); `ZZ` = generic "miscellaneous" item typed by hand |
| line_kind | `product` (goods), `service` (labour/assistance, hosting…), `fee` (shipping etc.) |
| group_name, family_name, brand_name | catalogue classification (group > family), brand |
| qty | quantity (negative on credit notes) |
| unit_price_net | unit price before VAT |
| net | line amount net of VAT, after discounts (negative on credit notes) |
| unit_cost, cost_source | cost per unit: `pmc` average cost at sale time; `last_purchase` item's last purchase price (fallback); `estimated` product without a recorded cost, costed at its family's (else overall) cost-to-sales ratio (~5% of sales); `zero_price_line` / `not_applicable` |
| line_role | `bundle` (PC bundle parent), `bundle_component` (price 0), `normal`. Bundle cost is counted once: `in_bundle` = price-0 component of a parent that carries the total cost (component costs 0); `in_components` = old-style parent with no cost whose price-0 components carry the real cost (parent costs 0) |
| cost, margin | `qty*unit_cost`, `net - cost` (**gross margin estimate**) |
| origin_doc_type / origin_doc_id | document converted into this invoice: `OSA` repair order, `ORC` quote, `GTC` delivery note… |

### `sales_lines`
Same as `sales_facts` but **all** lines including cancelled, internal and text lines (no cost/margin columns).

### `sales_docs` — one row per sales document
doc_id, doc_type, doc_type_name, doc_class, sign, is_internal, series, number, doc_date, year, quarter, month,
weekday (0=Sun), hour, customer_code, customer_name, customer_nif, is_cancelled, cancel_reason, net, vat, gross,
goods_net, services_net, item_count, terminal, created_by_user, cash_session.

### `customers`
customer_code, name, name2, address, address2, postal_code, nif, email, phone, customer_group, opened_on,
is_inactive, **is_walk_in** (1 for "Consumidor Final" / "cliente diverso" / "diversos" — exclude from customer rankings).

### `items` — catalogue
item_code, description, kind, group_code/name, family_code/name, brand_code/name, barcode, price_net, price_gross,
last_purchase_price, last_supplier, last_purchase_date, last_sale_date, stock_qty, main_supplier_code.

### `repairs` — repair orders (assistências, doc type `OSA`), one row per order
repair_id, opened_on, year, month, closed_at, status_code (`FEC` closed, `ABR` open, `PRO`, `INT` in progress),
status, customer_code, customer_name, equipment_type_code/equipment_type (notebook, desktop, printer…),
equipment_item, equipment_description, brand_code/brand_name, model, serial_number, reported_fault, accessories,
series, number, series_year (`repair_id` is not unique for series `VAZIA` in 2008/2009: join with `series_year`),
received_by_code (who opened/received the order — mostly the front desk), repair_technician_code (who repaired;
`assTec_tecnicos`; **not recorded since ~2021**), diagnosis (technician's findings), work_done, created_by_user,
quoted_gross, quoted_net (value on the order; repairs are usually **billed on a separate invoice** — see
`sales_facts.origin_doc_type = 'OSA'` (linked only from 2024) and `line_kind = 'service'`).
Caveats: `closed_at` only exists 2011–2019 (+ early 2020); status before 2021 is always FEC; about half of recent
orders carry no value; `reported_fault`/`diagnosis` are free text and can contain customer passwords.

### `repair_lines` — parts/labour recorded on repair orders
repair_id, year, item_code, description, line_kind, qty, net.

### `purchase_docs` — supplier documents
doc_id, doc_type (VFT purchase invoice, FTINC intra-EU, FTEXC extra-EU, VNC/DEVNC credit notes…), doc_type_name,
doc_date, year, month, supplier_code, supplier_name, is_cancelled, net (credit notes negative), gross.

### `suppliers`, `doc_types`
Lookups. `doc_types`: doc_type, description, module (VND sales, COM purchases, DCC current account…),
fiscal_type, doc_class, sign, is_internal.

## Raw tables worth knowing
`cab_vendas`/`lin_vendas` sales headers/lines · `Cab_Assistec`/`Lin_Assistec`/`assTec_intervencao_tecnica`
repairs (+ technician notes `avaria_encontrada`) · `cab_compras`/`lin_compras` purchases · `cab_recpag`/`lin_recpag`
receipts/payments · `cab_caixa`/`Lin_caixa` till sessions · `Clientes`, `Fornecedores`, `Artigos`, `Familias`,
`Grupos`, `Marcas` · `totais_clientes`, `totais_stocks` running totals · `log_atividades` user activity log.
Raw dates are `YYYYMMDD` or `YYYYMMDDHHMMSSmmm` text; `00000000…`/`18991230…` mean empty.
`_tables` lists every table with rows/columns; `_memo_files` lists extracted images/attachments
(`data/memo_files/<table>/…`), `_memo_texts` the text memos with their record number.

## Overheads, cash and receivables (raw tables, see `bi/queries/finance/`)
- Overheads **are recorded from 2021**: `Cab_DirCC_Cre` holds "outros credores" invoices (salaries, social security,
  rents, fuel, accountant, CHIP7 franchise fees, taxes, loans, vehicles); payments in `cab_recpag` code `POC`.
  `finance_operating_expenses_by_category` / `finance_profit_and_loss_by_year` classify them.
- Receivables: open amount = `total_documento − Total_liquidado` (VAT included); agrees with `totais_clientes`
  and `Clientes.saldo` (`finance_receivables_open`, `finance_receivables_aging`).
- Payments: `Lin_caixa` joined to `cab_caixa` (2022+); `_CX99` lines repeat the till-closing totals — never add them.
- Purchases traps: `lin_compras.Total_iva` is the line total **with** VAT (not the VAT); `cab_compras.Total_portes`
  misses most freight (use the PORTES lines).

## Privacy and security
- `utilizadores.password` and `Broker.PalavraPasse` hold credentials: the agent tools (`query`, `describe`) refuse
  them. Repair notes can contain customer passwords — never quote them.
- Customer contact data (phones, emails, addresses) is personal data (GDPR): keep `data/` private.

## Caveats
- Margin is an estimate: cost = average cost at sale time; ~5% of product sales have an estimated cost. Labour has
  no cost per line (wages are overheads, see above), so services show 100% gross margin.
- The current year is partial (data to the export date, 2026-11-08) — compare like-for-like periods.
- Before 2017 only repairs exist in this database (sales history starts 2017).
- Names/addresses are as typed in the shop; duplicates of the same customer under different codes can exist.

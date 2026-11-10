# gGest data dictionary

Data exported from the **gGest** ERP (Golfinho Software, WinDev/HFSQL). Built and tested on the database of a
computer shop (hardware sales, repairs/*assistências*, IT services and software); the schema is the same in
every gGest database, the company-specific meaning lives in `ggest.json` (see Configuration).

- Database: one SQLite file per gGest database (default `data/data.sqlite`; `--db` to choose): raw gGest tables
  (all values TEXT, exactly as exported) + **business views** (`bi/sql/semantic.sql` core, `bi/sql/ext/*.sql` per
  domain). Query the views; use raw tables only for details the views lack.
- **Data date**: the last document date in the snapshot. `today` in saved queries means this date
  (`management_kpi_snapshot` shows it). Compare like-for-like periods; the current year is partial.
- Money: EUR, **net of VAT** unless a column says `gross`/`vat`. Azores VAT rates (18%/16%) appear on sales,
  23% on mainland supplier invoices.
- Rules applied in the views: cancelled documents (`estado_doc = 1`, with `cancel_reason`) excluded from
  `sales_facts`; credit notes negative; internal documents (`is_internal`: internal consumption, sponsorship, and
  the types/series listed in the config, e.g. the sale of a company vehicle) excluded from `sales_facts`.

## Configuration (company-specific meaning)
`ggest.json` next to the database (or env `GGEST_CONFIG`) overrides `bi/config.default.json`; documented example
in `bi/config.example.json`. It is copied into `_bi_config`, `_bi_series_groups`, `_bi_expense_rules`,
`_bi_regions` by `uv run ggest build-views`.
- `internal_doc_types`, `internal_doc_name_like`: sales document types that are not trading revenue.
- `excluded_series_prefixes`: invoice series that are not trading revenue.
- `series_groups`: invoice series that are a business unit of their own (e.g. a franchise corner) →
  `sales_series_groups_by_year`.
- `expense_rules`: overhead categories by creditor code/name/document text → `expense_docs`,
  `finance_operating_expenses_by_category`, `finance_profit_and_loss_by_year`.
- `setup_*` saved queries show what the config currently does (skill `new-database-setup`).

## Domain views (details: `uv run ggest data_dictionary --topic <domain>` = `docs/domains/<domain>.md`)
- **sales**: `quote_docs`, `quote_lines`, `quote_outcomes` (quotes/pro-formas/orders and whether they became
  invoices), `delivery_notes`, `online_items`.
- **customers**: `customer_dim` (segment, NIF check, contact-presence flags — no contact values),
  `customer_activity` (every interaction, last contact), `customer_appointments`.
- **repairs**: `serial_history`, `serial_registry` (serial numbers, warranty terms and end dates),
  `repair_warranty` (was the device sold here, in warranty at opening), `repair_rmas`, `repair_models`.
- **finance**: `receivable_docs`, `payable_docs`, `expense_docs`, `payment_docs`, `payment_allocations`,
  `till_movements`, `recurring_contracts` (avenças), `vat_lines`, `tax_obligations`, `mb_references`.
- **stock**: `stock_items`, `stock_movements`, `stock_year_end`, `assembly_orders`/`assembly_components` (PC
  builds), `stock_purchase_lines`, `serial_movements`, `supplier_rmas`.
- **operations**: `activity_log` (user activity, no free text), `documents_created` (per user and module).

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
| line_kind | `product` (goods), `service` (labour/assistance, hosting…), `fee` (shipping etc.). Service work typed as a product line also counts as `service` with no cost (see `kind_rule`) |
| kind_rule | why a product line was counted as a service: `service_item` (the catalogue item is a service: kind E, a group in `service_group_names` or a code in `service_item_codes`) or `service_text` (no recorded cost, no stock movement, description like "consultadoria", "implementação", "reparação", "deslocação"… from `service_description_like`); NULL otherwise. Configurable in ggest.json; `product_item_codes` opts items out |
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
  rents, fuel, accountant, franchise fees, taxes, loans, vehicles); payments in `cab_recpag` code `POC`.
  `finance_operating_expenses_by_category` / `finance_profit_and_loss_by_year` classify them.
- Receivables: open amount = `total_documento − Total_liquidado` (VAT included); agrees with `totais_clientes`
  and `Clientes.saldo` (`finance_receivables_open`, `finance_receivables_aging`).
- Payments: `Lin_caixa` joined to `cab_caixa` (2022+); `_CX99` lines repeat the till-closing totals — never add them.
- Purchases traps: `lin_compras.Total_iva` is the line total **with** VAT (not the VAT); `cab_compras.Total_portes`
  misses most freight (use the PORTES lines).
- Current-account sign: `Documentos.mov_cc` (3 debit, 2 credit, 4 settled on the spot). Creditor invoice numbers
  (FTOC) and some payment numbers repeat across entities — always join with the entity. Year-end `_F*` records
  ("TRANSPORTE DO ANO") carry balances forward; they are not movements.

## Privacy and security
- gGest stores credentials readably (user passwords, e-mail/SMTP and web-shop passwords, API keys and tokens,
  terminal passwords, bank account numbers). The agent tools (`query`, `describe`) refuse those tables and any
  credential-like column. Repair free text (`reported_fault`, `diagnosis`, technician notes) can contain customer
  passwords/PINs: tools only return it for one order/device on request, never in bulk.
- Customer contact data (phones, emails, addresses) is personal data (GDPR): keep `data/` private. Views expose
  contact *presence* flags, not values, except where one customer's card is asked for.

## Caveats
- Margin is an estimate: cost = average cost at sale time; ~5% of product sales have an estimated cost. Labour has
  no cost per line (wages are overheads, see above), so services show 100% gross margin.
- The current year is partial (data up to the data date) — compare like-for-like periods.
- Before 2017 only repairs exist in this database (sales history starts 2017).
- Names/addresses are as typed in the shop; duplicates of the same customer under different codes can exist.

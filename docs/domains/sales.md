# Sales domain: invoices, quotes, delivery notes, products, pricing

Core views (`bi/sql/semantic.sql`): `sales_facts` (lines that count, with cost/margin), `sales_docs`, `sales_lines`,
`items`, `doc_types`. This domain adds `bi/sql/ext/sales.sql` (apply: `uv run ggest build-views --file bi/sql/ext/sales.sql`)
and the saved queries `bi/queries/sales/sales_*.sql` (`uv run ggest saved_queries --domain sales`).
Skills: `sales-report`, `quote-followup`, `product-lookup`, `pricing-review` (`.claude/skills/`).

## Views added

| view | raw tables | one row per | notes |
|---|---|---|---|
| `quote_docs` | `cab_outros` + `doc_types` | "other" customer document (module OTC) | `doc_kind`: quote / proforma / order / loan / workshop_consumption; `net` = total − VAT; `valid_until` from `data_venc` when later than the date; `is_cancelled` (`estado_doc = 1`); `line_count` = item lines (text lines excluded); `total_qty` = gGest `numero_itens`, which is the **sum of quantities, not a line count** |
| `quote_lines` | `lin_outros` + `Artigos`/`Grupos`/`Familias` | line | `converted_qty` (= `convertido`, qty carried into an invoice/note); `unit_cost` = line pmc, else the item's **current** last purchase price (`cost_source`), ZZ = unknown |
| `quote_outcomes` | quote_docs + `lin_vendas`/`lin_guias` origin links + `sales_facts` | ORC/FPF/ENC not cancelled | `linked_doc_id`, `invoiced_60d_net`, `first_invoice_date`, `days_to_invoice`, `age_days` (vs last sales date), `valid_days_left`, `outcome` (below). ~2 s: query it once per answer (CTE `AS MATERIALIZED`) |
| `delivery_notes` | `cab_guias` + `lin_guias` + `lin_vendas` origin links | delivery/transport note | `billing_status`: invoiced / after_invoice / not_linked; `invoiced_by`, `origin_doc_id`, `atcud`, `line_count` |
| `online_items` | `Ecom_Artigos` + `items` | item published to the web shop | active/visible/orderable flags; price & stock come from `items` (Ecom price columns are 0) |

## Document codes
- **Sales (module VND)**: FT invoice, FR invoice-receipt, FS simplified, FTGOL (own software series), NC/NCP credit
  notes; FRCIN/NCCIR internal consumption, FTPTC sponsorship, VIAT vehicle sales → excluded from `sales_facts`.
  Series are per year (`2025`, `CA17`, `G20`…); other series (e.g. `CHIP*` franchise) are grouped by config
  (`sales_series_groups_by_year`).
- **Other customer docs (module OTC, `cab_outros`)**: `ORC` quote (fiscal type OR), `FPF` pro-forma (PF), `ENC`
  customer order (NE), `ET`/`EPTTE`/`EMPTC` technical loan (equipment lent), `CONOF`/`CSOF` workshop consumption.
  None is revenue. Supplier-side equivalents (module OTF) are not here.
- **Delivery notes (module GIC, `cab_guias`)**: `GTC` transport note, `GTCG` global, `GRC` remittance, `GDC`
  return, `GCC` consignment, `GMA` own assets, `NGT` (old). Communicated to the tax authority (`atcud`, `codigo_at`).
- `tipos_documentos` = document *modules* (VND, OTC, GIC, OSA, COM…), `Documentos` (= `doc_types`) = document codes.
- `Tipos_artigos`: item types A goods, E services, F shipping/fees, H labour, I fixed assets… (`sales_facts.line_kind`
  maps A→product, E→service, F→fee).

## Conversion links (quote → invoice)
- Invoice line: `lin_vendas.origem_codigo/origem_serie/origem_numero/origem_linha` (ORC, FPF, ENC, GTC, OSA, FT…).
- Delivery note line: `lin_guias.origem_*` (ORC/FPF/ENC); the invoice then references the note (origem GTC).
- Quote line: `lin_outros.convertido` = quantity already converted.
- **Trap:** most invoices are retyped, not converted, so links cover a small minority of quotes (invoice links from 2020;
  earlier only `convertido`). `quote_outcomes.outcome`: `converted_linked` (any link / converted qty) · `likely_won`
  (same customer invoiced ≥ 50 % of the quote within 60 days) · `open` (still valid: `valid_until` ≥ today when set,
  else ≤ 60 days old) · `partial` (expired, < 50 % invoiced) · `not_won` (expired, nothing). Heuristic limits: purchases under another customer code are missed; unrelated purchases count.
- Quotes store **no cost** (pmc is 0 on quote lines); generic `ZZ` lines are often most of the quoted value, so
  product-group analysis of quotes is partial.

- Quotes are often re-issued (variants, revisions): `sales_quotes_followup` flags `variant_of` (same customer, within
  7 days, or net within 3 % within 90 days) and gives `open_net_dedup`; never add up raw open quotes as pipeline.
- Customer segment: use `customer_dim.segment` (customers domain) — `sales_customer_segments_by_year`, `sales_big_deals`.

## Delivery notes traps
- Not every note is a sale to invoice: some accompany goods already invoiced (text line quoting the invoice →
  `after_invoice`), some carry customer equipment for repair, some ship franchise (Chip7) orders invoiced in their
  own series without a link. `sales_delivery_notes_not_invoiced` looks for a same-customer invoice within 30 days.
- Links only exist from late 2021.

## Pricing / discounts
- Catalogue: `items.price_net` (pvp1, net of VAT), `price_gross`, `last_purchase_price` (`ultc_doc_precoliq`, net
  unit price of the last purchase). Supplier purchase lines: `lin_compras` (`Total` = net line, `Total_iva` = line
  WITH VAT; returns DEVNC negative).
- Discounts: `cab_vendas.total_descontos_lin` / `total_descontos_cab`; small in practice — price cuts are typed in
  the unit price, hence `sales_discounted_lines` compares with today's catalogue price.
- Margin caveats (see `sales_data_quality_by_year`): bundles (`line_role`), estimated cost, unit mismatch (box vs
  unit), domains/subscriptions with fixed/annual cost, corrupted average cost.

## Tables checked and skipped
- `promocoes`, `promocoes_artigos` (one test promotion), `vales_descontos` (2 rows), `Artigos_Associados` /
  `Artigos_Substitutos` / `Artigos_Conjuntos` (demo rows), `precos_clientes*` / `atualizar_precos_artigos` /
  `cab_obras_*` / `encomendas_artcli` / `Ecom_Encomendas*` (empty).
- `vendedores`: salesperson table; documents carry `vendedor = 1` almost always → use `created_by_user`
  (`management_sales_by_user`).
- `moradas_documentos`: load/unload addresses per document (all modules; personal data) — logistics only.
- `cab_efatura`/`lin_efatura`: supplier invoices from the tax portal (purchases, finance domain).
- `Ecom_Grupos`, `Ecom_Artigos_Marcas`: web-shop category/brand mapping (gGest code ↔ shop id).
- `Subfamilias`: optional third catalogue level, set on a minority of items (not in the core views).

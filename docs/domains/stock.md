# Stock, purchasing & assembly (gGest)

Views in `bi/sql/ext/stock.sql` (apply: `py -m bi build-views --file bi/sql/ext/stock.sql`), saved queries in
`bi/queries/stock/`, skills `reorder-suggestions`, `stock-cleanup`, `stock-check`, `supplier-review`.
Finance keeps `finance_stock_value_by_group`, `finance_dead_stock_items`, `finance_top_suppliers`,
`finance_purchases_*`, `finance_freight_costs_by_year`.

## Views

| view | grain | source / notes |
|---|---|---|
| `stock_items` | one row per catalogue item | `Artigos` + `preco_stocks` (latest year `pmc`) + `Artigos_Armazem` (min/max). qty_on_hand = `stock_real`; qty_available = `stock_disponivel`; qty_reserved = `stock_cativo`; qty_on_customer_order / qty_on_supplier_order = `stock_encomendas` / `stock_requisicoes`; unit_cost = pmc, else last purchase net cost (`cost_source`); stock_value; last purchase (date, net unit cost, doc, supplier) from the latest real purchase invoice line in `lin_compras` (the card fields `ultc_doc_*` are unreliable: they can point to ENTD/SAID/DEVNC/PRCE or hold a wrong price); `cost_warning` = `pmc_vs_last_cost` when pmc and last cost differ > 20 %; `is_stock_item` = 0 for non-stocked goods (groups SOFTWARE, INTERNET E CLOUD, SERVIÇOS, PORTES, TAXAS…, licences/hosting/subscriptions by description, services and fees); last sale from the item card |
| `stock_movements` | one row per document line that moved real stock | union of `lin_vendas`, `lin_compras`, `lin_outros`, `lin_producao`, `Lin_Stocks`; `movement_kind`, `direction`, signed `qty`, `unit_cost`, `value_at_cost`, `unit_price`, `entity_code` + `entity_kind` (customer/supplier) |
| `stock_year_end` | item × closed year | year-closing opening balances (`Lin_Stocks` doc `_FE01` of year N+1 = stock on 31-12-N), qty × pmc |
| `assembly_orders` / `assembly_components` | one row per build / per component line | `lin_producao` PRCE (built item enters) / PRCS (components leave) |
| `stock_purchase_lines` | supplier document line | `lin_compras` + header `cab_compras`; returns negative; `unit_cost_net` = line Total / qty |
| `serial_movements` | serial × document | `lin_mov_series` + `Artigos_series` (warranty years, status) |
| `supplier_rmas` | RMA sent to a supplier | `assTec_RMA` (contact and fault texts left out) |

## Stock rules
- **Which documents move stock**: `Documentos.var_stk = 'REAL'` and `sinal_stk` `+`/`-`, line flag `movstock = 1`
  (`mov_stock` in `Lin_Stocks`/`lin_producao`), cancelled sales lines (`estado_doc = 1`) excluded. Built this way the
  ledger equals the monthly totals `totais_stocks` (ent01..12 − sai01..12) for 99.9 % of items, and opening `_FE01` +
  ledger = `Artigos.stock_real` for ~99.7 %. `stock_reconciliation_check` lists the exceptions.
- `var_stk = 'GUIAS'` (delivery notes GRC/GTCG…) only affects `stock_disponivel`; `GTC` moves nothing — the invoice
  converted from it moves the stock. Quotes (ORC), pro-formas (FPF), customer orders (ENC) and repair orders (OSA)
  do not move stock (OSA parts are moved by the invoice or a `SAID`).
- Movement kinds: FT/FR/FS/FTGOL/VIAT/ND sale · NC/NCP/NCCIR sale_return · FRCIN/CI internal_use · FTPTC sponsorship ·
  VFT/VFR/VFS/FTINC/FTEXC/FADIA/VND purchase · DEVNC/VNC/VNCP/NCADI purchase_return · PRCE assembly_in · PRCS
  assembly_out · ENTD/STKE adjustment_in · SAID/STKS adjustment_out · SSTKA write_off · CG warranty_use ·
  CONOF/CSOF workshop_use · EMPTC/EPTTE loan_out · SCV other.
- Year closing documents `_FE01..05` / `_FS01..05` live in `Lin_Stocks` with empty dates: never add them to the
  ledger; `_FE01` is the 1-January opening stock (also valued: `pmc`).
- Stock-document headers (`Cab_Stocks`) carry no reason text nor entity: an ENTD/SAID can be a correction, a part
  used in a repair, a sample or a loss.
- One warehouse (`armazem` = `VAZIO`, "Armazém base"). `Artigos_Armazem` min/max stock is practically unused, so
  reorder points are computed from demand.

## Costs and values
- Average cost: `preco_stocks.pmc` (current), `pmc01..12` monthly, `puc*` last purchase cost; `lin_vendas.pmc` is the
  cost at sale time; `lin_compras.pmc` = net unit cost after discount (= Total / qty).
- `lin_compras.Total` is net of VAT after line discounts; `Total_iva` is the line total WITH VAT (misleading name).
- **Assembly**: `PRCE.preco` is the TOTAL cost of the batch (= Σ PRCS qty × preco), not the unit cost; PRCE with qty 0
  = built item not stocked. Assembled items often get a new item code per build (e.g. `chip7_*` models); some generic
  codes are reused for many builds.
- AT inventory communication (`InvAT_Cab` / `InvAT_Lin`, one per year from 2020) holds the same item list and
  totals as `_FE01` (differences of up to ~0.5 %). `Cab_INV`/`Lin_INV` are physical counts (few, 2020–2024).

## Purchasing and suppliers
- Supplier orders (`NREQ`, var_stk REQUISICOES) and supplier quotes (`VORC`) exist as types but are not used: no
  lead-time data. `Artigos_Fornecedores` (supplier item codes) is almost empty; use the item card's last supplier
  (`ultc_doc_*`) and `for_principal`.
- Returns to suppliers: credit notes DEVNC/VNC/VNCP/NCADI. Warranty RMAs (`assTec_RMA`) only 2020-05 → 2024-04; the
  RMA's `data_abertura` is often later than `envio_data` (registered after shipping).
- Serial numbers: `lin_mov_series` (VFT purchase, FT/FR sale, OSA repair, PRCS/PRCE assembly, GTC…), `Artigos_series`
  `Estado` 0 = in stock / 1 = out (not fully maintained: more serials flagged in stock than units on hand),
  `Prazo_Garantia` = warranty years.

## Unused / config tables
`totais_stocks_temp` (temp copy), `Tipos_Stock` / `stock_variaveis` (formulas: available = REAL − CATIVO − GUIAS),
`cab_MobiStock`/`lin_MobiStock` (handheld terminal tests, 2020–2024), `Cab_Preparacao` (31 docs in preparation),
`armazem`, `Expedicoes` (shipping methods), `PRODUCAO_*` (empty).

## Traps
- Item codes are case-sensitive text; descriptions contain mojibake from the source in some rows.
- `stock_items.last_sale_date` comes from the item card; `stock_movements` gives the true last sale.
- Toners/consumables from the 2017 opening stock are still on the books; consumables and spares hold most idle value.

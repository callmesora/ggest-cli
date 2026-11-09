# Repairs / after-sales (assistência técnica) — domain notes

Generic gGest knowledge for the repair workshop, serial numbers, warranty and supplier RMA. Views live in
`bi/sql/ext/repairs.sql` (on top of the core views `repairs` and `repair_lines` in `bi/sql/semantic.sql`);
saved queries in `bi/queries/repairs/`; skills `repair-desk`, `device-history`, `warranty-check`, `repair-quality`.

## Views added

| View | Grain | Built from | Use |
|---|---|---|---|
| `serial_history` | one serial on one document line | `lin_mov_series` (+ `Lin_Assistec.Numero_Serie` before 2020-03) | timeline of a serial: purchase, sale, return, repair part, loan… |
| `serial_registry` | one (item, serial) of the registry | `Artigos_series` + `lin_mov_series` | warranty term, first purchase (supplier), last valid sale (customer), warranty end |
| `repair_warranty` | one repair order (2017+) | `Cab_Assistec` + sales serials + `Artigos_series` | was the device sold here, to whom, in warranty when it came in |
| `repair_rmas` | one supplier RMA | `assTec_RMA` | RMA dates, supplier, item/serial, linked repair order and sale |
| `repair_models` | one model code | `assTec_modelos` + `Marcas` | decode `Cab_Assistec.Modelo` codes (M0001…) used 2018-2020 |

The stock domain has similar views `serial_movements` / `supplier_rmas` (stock angle); the repairs views add
the movement type, entity names, the pre-2020 repair-part serials and the warranty logic.

## Raw tables

| Table | Content | Notes |
|---|---|---|
| `Cab_Assistec` / `Lin_Assistec` | repair order header / lines (doc type `OSA`) | core view `repairs`, `repair_lines` |
| `assTec_intervencao_tecnica` | technician part of the order (1:1): diagnosis, work done, technician, close | join on `codigo, serie, numero, ano` — **include `codigo`**, the index starts with it |
| `assTec_estados` | `ABR` aberta, `INT` em intervenção, `PRO` pronta em testes, `fec` fechada | case differs (`fec`): compare with `upper()` |
| `assTec_tecnicos` | technicians (codes used in `tecnico`) | technician not recorded since 2020-04 |
| `assTec_tipos_equipamentos` | equipment type codes (`not`, `des`, `imp`, `tab`…) | `tel` (phone) missing from the table |
| `assTec_modelos` | model codes per brand | only referenced by orders of 2018-2020 |
| `assTec_RMA` | supplier warranty returns (RMA) | small; status `1` open, `4` closed; many open ones are stale |
| `assTec_Tipo_Intervencao`, `assTec_acessorios` | tiny lookups (reparação/troca/outra; transformador, rato, mala…) | not used by the orders |
| `assTec_contratos`, `assTec_equipamentos` | maintenance contracts / customer equipment register | practically unused (1-2 rows) |
| `Artigos_series` | serial registry per item: `Tipo_Garantia` (1 = years, 2 = months), `Prazo_Garantia`, `Estado` | bulk-created when the module was activated; `Estado` is not a reliable in/out-of-stock flag |
| `lin_mov_series` | serial on a document line: `Codigo, Serie, Numero, Linha, Entidade, Artigo, Serie_Artigo, Data, estado_doc, creditado` | `Entidade` = supplier for purchase docs, customer otherwise, `0` for internal docs |
| `OFICINA_*` | vehicle-workshop module (matrícula, mecânico…) | not used by a computer shop (1-3 test rows): ignore |
| `Controlo_Assiduidade` | staff clock-in/out | few rows, not linked to repairs: ignore |

## Key codes and joins

- Serial documents (`lin_mov_series.Codigo`): purchase `VFT` (also `FTINC` intra-EU, `FTEXC`, `NGT`); sale `FT`, `FR`
  (also `FRCIN`, `FTPTC`); customer credit `NC`, `NCP`; return to supplier `DEVNC`, `VNC`; repair order `OSA` (the
  serial of a **part** fitted/sold on the order, not of the device repaired); `ORC` quote, `ENC` order, `GTC`
  delivery note, `ET`/`EMPTC` technical loan, `CI`/`CONOF`/`CSOF`/`CG` internal/warranty consumption,
  `PRCS`/`PRCE` assembly, `SAID`/`ENTD`/`SSTKA` stock adjustments.
- Document id = `Codigo || ' ' || Serie || '/' || Numero` (same as `sales_docs.doc_id`, `purchase_docs.doc_id`).
- Device serial of a repair = `Cab_Assistec.Numero_Serie` (free text). Match serials with `lower(trim())`; ignore
  serials shorter than 6 characters (internal numbers like "652").
- RMA → repair order: `origem_int_codigo/serie/numero`; → purchase: `doc_compra_*` (supplier `doc_compra_entidade`);
  → sale: `doc_venda_*`.
- Order → invoice: `sales_facts.origin_doc_id = repairs.repair_id` (only since 2024-03). `sales_facts.origin_doc_id`
  has no index: build a `DISTINCT` set first instead of a correlated `EXISTS`.

## Traps

- **Free text holds passwords/PINs** (`Avaria_Descrita`, sometimes diagnosis/RMA notes). Never list them in bulk;
  `repairs_device_timeline` shows technician notes for one serial only on request.
- Close date and repairing technician are empty since 2020: no turnaround or per-technician workload for recent
  years. `Cab_Assistec.Tecnico` is the receiving person; `inserido_util` (user who typed the order) is the best proxy.
- Status before 2021 is "closed" in bulk; only recent status is informative. `PRO` orders are often never closed:
  `repairs_open_backlog` flags `probably_closed` (PRO with no change in `Cab_Assistec.alterado_data` for > 60 days,
  or already invoiced) and hides them by default (`view=active`; `view=stale` for cleanup).
- Serial tracking on sales starts 2017 and became systematic later; matching rates rise over time (trend effect).
- Warranty term in `Artigos_series` is the shop's setting, not necessarily the legal term (PT: 3 years for consumer
  goods from 2022); queries assume 24 months when it is missing and flag it.
- The same customer often has several codes: a device sold to code A may come in under code B (`same_customer = 0`).
- Accents were lost in text (shown as `�`): keyword rules use `_` wildcards.
- `serial_registry` aggregates the whole `lin_mov_series` (~1-2 s): filter it by `serial_key`, don't join it row by row.

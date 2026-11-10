-- Repairs / after-sales extension views (assistência técnica, serial numbers, supplier RMA).
-- Depends only on raw gGest tables and core views. Applied with: uv run ggest build-views --file bi/sql/ext/repairs.sql
-- Free-text repair fields (fault, diagnosis, RMA notes) can contain customer passwords/PINs: these views expose
-- them only where needed for a single-order lookup; saved queries must not list them in bulk.

-- Serial-number movements -------------------------------------------------------------------------
-- One row per serial number on a document line: purchases (VFT), sales (FT/FR...), credit notes, returns to
-- supplier, parts fitted in repair orders (OSA), quotes, loans, internal use... Source lin_mov_series (2017+;
-- repair-order parts only since 2020-03) plus the older part serials typed on repair lines (Lin_Assistec, < 2020-03).
DROP VIEW IF EXISTS serial_history;
CREATE VIEW serial_history AS
WITH mv AS (
  SELECT trim(m.Serie_Artigo) AS serial_number, m.Artigo AS item_code, m.Codigo AS doc_type,
         m.Codigo || ' ' || m.Serie || '/' || m.Numero AS doc_id, CAST(m.Linha AS INTEGER) AS line,
         date(substr(m.Data,1,4)||'-'||substr(m.Data,5,2)||'-'||substr(m.Data,7,2)) AS movement_date,
         m.Entidade AS entity_code,
         CASE WHEN m.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
         CASE WHEN m.creditado = '1' THEN 1 ELSE 0 END AS is_credited,
         'lin_mov_series' AS source
  FROM lin_mov_series m WHERE trim(m.Serie_Artigo) <> ''
  UNION ALL
  SELECT trim(l.Numero_Serie), NULLIF(l.Artigo,''), 'OSA', l.Codigo || ' ' || l.serie || '/' || l.numero,
         CAST(l.linha AS INTEGER),
         date(substr(l.data_doc,1,4)||'-'||substr(l.data_doc,5,2)||'-'||substr(l.data_doc,7,2)),
         l.entidade_codigo, CASE WHEN l.estado_doc = '1' THEN 1 ELSE 0 END, 0, 'Lin_Assistec'
  FROM Lin_Assistec l WHERE trim(l.Numero_Serie) <> '' AND l.data_doc < '20200310')
SELECT mv.serial_number, lower(mv.serial_number) AS serial_key, mv.item_code, trim(a.descricao) AS item_description,
       mv.movement_date, mv.doc_type, dt.description AS doc_type_name, mv.doc_id, mv.line,
       CASE WHEN mv.doc_type IN ('VFT','FTINC','FTEXC','NGT') THEN 'purchase'
            WHEN mv.doc_type IN ('DEVNC','VNC') THEN 'supplier_return'
            WHEN mv.doc_type IN ('FT','FR','FRCIN','FTPTC') THEN 'sale'
            WHEN mv.doc_type IN ('NC','NCP','NCCIR') THEN 'customer_return'
            WHEN mv.doc_type = 'OSA' THEN 'repair_part'
            WHEN mv.doc_type IN ('CG') THEN 'warranty_consumption'
            WHEN mv.doc_type IN ('CI','CONOF','CSOF') THEN 'internal_use'
            WHEN mv.doc_type IN ('ET','EMPTC','EPTTE') THEN 'loan'
            WHEN mv.doc_type IN ('GTC') THEN 'delivery_note'
            WHEN mv.doc_type IN ('ORC','FPF','ENC') THEN 'quote_or_order'
            WHEN mv.doc_type IN ('PRCS','PRCE') THEN 'assembly'
            ELSE 'stock_adjustment' END AS movement,
       CASE WHEN mv.doc_type IN ('VFT','FTINC','FTEXC','NGT','DEVNC','VNC') THEN 'supplier'
            WHEN mv.entity_code IN ('', '0') THEN 'internal' ELSE 'customer' END AS entity_kind,
       NULLIF(mv.entity_code,'0') AS entity_code,
       CASE WHEN mv.doc_type IN ('VFT','FTINC','FTEXC','NGT','DEVNC','VNC') THEN trim(f.descricao)
            WHEN mv.entity_code NOT IN ('', '0') THEN trim(c.descricao) END AS entity_name,
       mv.is_cancelled, mv.is_credited, mv.source
FROM mv
LEFT JOIN Artigos a ON a.Codigo = mv.item_code
LEFT JOIN doc_types dt ON dt.doc_type = mv.doc_type
LEFT JOIN Clientes c ON c.Codigo = mv.entity_code AND mv.doc_type NOT IN ('VFT','FTINC','FTEXC','NGT','DEVNC','VNC')
LEFT JOIN Fornecedores f ON f.Codigo = mv.entity_code AND mv.doc_type IN ('VFT','FTINC','FTEXC','NGT','DEVNC','VNC');

-- Serial-number registry with warranty ------------------------------------------------------------
-- One row per (item, serial) of the gGest serial registry (Artigos_series, created 2020-11 with the history then
-- re-typed; ~2 000 new serials/year since), with purchase (first non-cancelled VFT) and last sale (non-cancelled,
-- not credited) from lin_mov_series. warranty_months: Tipo_Garantia 1 = years, 2 = months (Prazo_Garantia);
-- nonsense terms (> 10 years) -> NULL. warranty_end = sold_on + warranty_months (customer warranty);
-- supplier_warranty_end = purchased_on + warranty_months (approximation of the supplier/RMA warranty).
DROP VIEW IF EXISTS serial_registry;
CREATE VIEW serial_registry AS
WITH mv AS (
  SELECT m.Artigo, lower(trim(m.Serie_Artigo)) AS k, m.Codigo, m.Data, m.Entidade,
         m.Codigo || ' ' || m.Serie || '/' || m.Numero AS doc_id
  FROM lin_mov_series m WHERE m.estado_doc <> '1' AND m.creditado <> '1'),
buy AS (SELECT Artigo, k, min(Data) AS d FROM mv WHERE Codigo IN ('VFT','FTINC','FTEXC','NGT') GROUP BY 1,2),
buy1 AS (SELECT mv.Artigo, mv.k, min(mv.doc_id) AS doc_id, min(mv.Entidade) AS ent, buy.d
         FROM mv JOIN buy ON buy.Artigo = mv.Artigo AND buy.k = mv.k AND buy.d = mv.Data
         WHERE mv.Codigo IN ('VFT','FTINC','FTEXC','NGT') GROUP BY 1,2),
sale AS (SELECT Artigo, k, max(Data) AS d, count(*) AS n FROM mv WHERE Codigo IN ('FT','FR','FRCIN','FTPTC') GROUP BY 1,2),
sale1 AS (SELECT mv.Artigo, mv.k, max(mv.doc_id) AS doc_id, max(mv.Entidade) AS ent, sale.d, sale.n
          FROM mv JOIN sale ON sale.Artigo = mv.Artigo AND sale.k = mv.k AND sale.d = mv.Data
          WHERE mv.Codigo IN ('FT','FR','FRCIN','FTPTC') GROUP BY 1,2),
reg AS (
  SELECT s.Codigo AS item_code, trim(s.Serie) AS serial_number, lower(trim(s.Serie)) AS k,
         CASE WHEN s.Tipo_Garantia = '1' AND CAST(s.Prazo_Garantia AS INTEGER) BETWEEN 1 AND 10
                THEN CAST(s.Prazo_Garantia AS INTEGER) * 12
              WHEN s.Tipo_Garantia = '2' AND CAST(s.Prazo_Garantia AS INTEGER) BETWEEN 1 AND 120
                THEN CAST(s.Prazo_Garantia AS INTEGER) END AS warranty_months,
         date(substr(s.inserido_data,1,4)||'-'||substr(s.inserido_data,5,2)||'-'||substr(s.inserido_data,7,2)) AS registered_on
  FROM Artigos_series s)
SELECT reg.item_code, trim(a.descricao) AS item_description, reg.serial_number, reg.k AS serial_key,
       reg.registered_on, reg.warranty_months,
       date(substr(b.d,1,4)||'-'||substr(b.d,5,2)||'-'||substr(b.d,7,2)) AS purchased_on,
       b.doc_id AS purchase_doc_id, b.ent AS supplier_code, trim(f.descricao) AS supplier_name,
       date(substr(sl.d,1,4)||'-'||substr(sl.d,5,2)||'-'||substr(sl.d,7,2)) AS sold_on,
       sl.doc_id AS sale_doc_id, sl.ent AS customer_code, trim(c.descricao) AS customer_name, sl.n AS times_sold,
       CASE WHEN sl.d IS NOT NULL AND reg.warranty_months IS NOT NULL THEN
            date(substr(sl.d,1,4)||'-'||substr(sl.d,5,2)||'-'||substr(sl.d,7,2), '+' || reg.warranty_months || ' months') END AS warranty_end,
       CASE WHEN b.d IS NOT NULL AND reg.warranty_months IS NOT NULL THEN
            date(substr(b.d,1,4)||'-'||substr(b.d,5,2)||'-'||substr(b.d,7,2), '+' || reg.warranty_months || ' months') END AS supplier_warranty_end
FROM reg
LEFT JOIN buy1 b ON b.Artigo = reg.item_code AND b.k = reg.k
LEFT JOIN sale1 sl ON sl.Artigo = reg.item_code AND sl.k = reg.k
LEFT JOIN Artigos a ON a.Codigo = reg.item_code
LEFT JOIN Fornecedores f ON f.Codigo = b.ent
LEFT JOIN Clientes c ON c.Codigo = sl.ent;

-- Supplier RMA (warranty returns to the supplier) ------------------------------------------------
-- assTec_RMA: few records (module used 2020-2024; most RMAs are only mentioned in repair notes). Links the RMA to the
-- repair order (origin), the purchase document (supplier) and the original sale. status: 1 = open, 4 = closed.
DROP VIEW IF EXISTS repair_rmas;
CREATE VIEW repair_rmas AS
SELECT CAST(r.numero AS INTEGER) AS rma_number, NULLIF(r.numero_externo,'') AS supplier_rma_ref,
       r.estado AS status_code, CASE r.estado WHEN '1' THEN 'open' WHEN '4' THEN 'closed' ELSE r.estado END AS status,
       date(substr(r.data_abertura,1,4)||'-'||substr(r.data_abertura,5,2)||'-'||substr(r.data_abertura,7,2)) AS opened_on,
       CASE WHEN r.origem_int_codigo <> '' THEN r.origem_int_codigo||' '||r.origem_int_serie||'/'||r.origem_int_numero END AS repair_id,
       NULLIF(r.cliente_codigo,'') AS customer_code, trim(c.descricao) AS customer_name,
       NULLIF(r.artigo,'') AS item_code, trim(a.descricao) AS item_description, NULLIF(r.marca,'') AS brand_code,
       NULLIF(trim(r.numero_serie),'') AS serial_number,
       NULLIF(r.doc_compra_entidade,'') AS supplier_code, trim(f.descricao) AS supplier_name,
       CASE WHEN r.doc_compra_numero <> '' THEN COALESCE(NULLIF(r.doc_compra_codigo,''),'VFT')||' '||r.doc_compra_serie||'/'||r.doc_compra_numero END AS purchase_doc_id,
       CASE WHEN r.doc_compra_data > '19000000' THEN date(substr(r.doc_compra_data,1,4)||'-'||substr(r.doc_compra_data,5,2)||'-'||substr(r.doc_compra_data,7,2)) END AS purchased_on,
       CASE WHEN r.doc_venda_numero <> '' THEN COALESCE(NULLIF(r.doc_venda_codigo,''),'FT')||' '||r.doc_venda_serie||'/'||r.doc_venda_numero END AS sale_doc_id,
       CASE WHEN r.doc_venda_data > '19000000' THEN date(substr(r.doc_venda_data,1,4)||'-'||substr(r.doc_venda_data,5,2)||'-'||substr(r.doc_venda_data,7,2)) END AS sold_on,
       CASE WHEN r.garantia_data > '19000000' THEN date(substr(r.garantia_data,1,4)||'-'||substr(r.garantia_data,5,2)||'-'||substr(r.garantia_data,7,2)) END AS warranty_end,
       CASE WHEN r.envio_data > '19000000' THEN date(substr(r.envio_data,1,4)||'-'||substr(r.envio_data,5,2)||'-'||substr(r.envio_data,7,2)) END AS shipped_on,
       NULLIF(r.envio_transp,'') AS carrier, CAST(NULLIF(r.envio_transp_custos,'') AS REAL) AS shipping_cost,
       CASE WHEN r.rececao_data > '19000000' THEN date(substr(r.rececao_data,1,4)||'-'||substr(r.rececao_data,5,2)||'-'||substr(r.rececao_data,7,2)) END AS received_back_on,
       r.resolFor_acao AS supplier_action_code, r.resolCli_acao AS customer_action_code,
       NULLIF(trim(r.resolFor_obs),'') AS supplier_resolution_note, NULLIF(trim(r.resolCli_obs),'') AS customer_resolution_note,
       NULLIF(trim(r.resolFor_nr_serie),'') AS replacement_serial
FROM assTec_RMA r
LEFT JOIN Clientes c ON c.Codigo = r.cliente_codigo
LEFT JOIN Artigos a ON a.Codigo = r.artigo
LEFT JOIN Fornecedores f ON f.Codigo = r.doc_compra_entidade;

-- Repair orders with device warranty context ------------------------------------------------------
-- One row per repair order (2017+, when serial tracking of sales exists) with the device serial matched (case-
-- insensitive, serials >= 6 chars) against serials sold by the shop: was the device sold here, when, and was it
-- still under the customer warranty when it came in, plus order value and customer. No free text.
-- Self-contained (does not join the repairs view, so it stays fast in aggregates).
DROP VIEW IF EXISTS repair_warranty;
CREATE VIEW repair_warranty AS
WITH sold AS (
  SELECT lower(trim(m.Serie_Artigo)) AS k, max(m.Data) AS d, max(m.Artigo) AS item_code,
         max(m.Codigo||' '||m.Serie||'/'||m.Numero) AS sale_doc_id, max(m.Entidade) AS sold_to
  FROM lin_mov_series m
  WHERE m.Codigo IN ('FT','FR','FRCIN','FTPTC') AND m.estado_doc <> '1' AND length(trim(m.Serie_Artigo)) >= 6
  GROUP BY 1),
wm AS (SELECT lower(trim(Serie)) AS k, max(CASE WHEN Tipo_Garantia = '1' AND CAST(Prazo_Garantia AS INTEGER) BETWEEN 1 AND 10 THEN CAST(Prazo_Garantia AS INTEGER)*12
                                                WHEN Tipo_Garantia = '2' AND CAST(Prazo_Garantia AS INTEGER) BETWEEN 1 AND 120 THEN CAST(Prazo_Garantia AS INTEGER) END) AS months
       FROM Artigos_series GROUP BY 1),
r AS (
  SELECT r.Codigo || ' ' || r.serie || '/' || r.numero AS repair_id, r.ano AS series_year,
         date(substr(r.data_doc,1,4)||'-'||substr(r.data_doc,5,2)||'-'||substr(r.data_doc,7,2)) AS opened_on,
         CAST(substr(r.data_doc,1,4) AS INTEGER) AS year, upper(r.Estado_Codigo) AS status_code,
         r.entidade_codigo AS customer_code, trim(r.entidade_descricao) AS customer_name,
         lower(r.tipo_equipamento) AS equipment_type_code, r.Marca AS brand_code,
         CAST(r.total_documento AS REAL) - CAST(r.Total_iva AS REAL) AS quoted_net,
         NULLIF(trim(r.Numero_Serie),'') AS serial_number, lower(trim(r.Numero_Serie)) AS k
  FROM Cab_Assistec r WHERE r.data_doc >= '2017')
SELECT r.repair_id, r.series_year, r.opened_on, r.year, r.status_code, r.customer_code, r.customer_name,
       r.equipment_type_code, te.descricao AS equipment_type, b.Descricao AS brand_name, r.quoted_net,
       r.serial_number,
       CASE WHEN sold.k IS NOT NULL THEN 1 ELSE 0 END AS sold_here,
       date(substr(sold.d,1,4)||'-'||substr(sold.d,5,2)||'-'||substr(sold.d,7,2)) AS sold_on,
       sold.sale_doc_id, sold.item_code AS sold_item_code, sold.sold_to AS sold_to_customer_code,
       CASE WHEN sold.k IS NOT NULL THEN CASE WHEN sold.sold_to = r.customer_code THEN 1 ELSE 0 END END AS same_customer,
       COALESCE(wm.months, CASE WHEN sold.k IS NOT NULL THEN 24 END) AS warranty_months,   -- default 24 (consumer law, 3 y since 2022 in PT for new goods)
       CASE WHEN sold.k IS NOT NULL THEN
            date(substr(sold.d,1,4)||'-'||substr(sold.d,5,2)||'-'||substr(sold.d,7,2), '+' || COALESCE(wm.months, 24) || ' months') END AS warranty_end,
       CASE WHEN sold.k IS NULL THEN NULL
            WHEN r.opened_on <= date(substr(sold.d,1,4)||'-'||substr(sold.d,5,2)||'-'||substr(sold.d,7,2), '+' || COALESCE(wm.months, 24) || ' months')
            THEN 1 ELSE 0 END AS in_warranty,
       CAST(julianday(r.opened_on) - julianday(substr(sold.d,1,4)||'-'||substr(sold.d,5,2)||'-'||substr(sold.d,7,2)) AS INTEGER) AS device_age_days
FROM r
LEFT JOIN sold ON sold.k = r.k AND length(r.k) >= 6
LEFT JOIN wm ON wm.k = r.k AND sold.k IS NOT NULL
LEFT JOIN assTec_tipos_equipamentos te ON lower(te.codigo) = r.equipment_type_code
LEFT JOIN Marcas b ON b.Codigo = r.brand_code;

-- Device model codes ------------------------------------------------------------------------------
-- Cab_Assistec.Modelo held a code of assTec_modelos (M0001...) in 2018-2020; before and after it is empty/free text.
DROP VIEW IF EXISTS repair_models;
CREATE VIEW repair_models AS
SELECT m.codigo AS model_code, trim(m.descricao) AS model_name, m.marca AS brand_code, b.Descricao AS brand_name
FROM assTec_modelos m LEFT JOIN Marcas b ON b.Codigo = m.marca;

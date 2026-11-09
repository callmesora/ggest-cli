-- Stock, purchasing and assembly views (domain: stock). Depends only on core views and raw gGest tables.
-- Docs: docs/domains/stock.md

-- Current stock per item --------------------------------------------------------------------------
-- Quantity = Artigos.stock_real (reconciles with opening balance + stock_movements for ~99.7% of items).
-- Last purchase = latest REAL purchase line (VFT/VFR/VFS/FTINC/FTEXC/VFTC, qty > 0) from lin_compras: the item card
-- fields ultc_doc_* are unreliable (can point to ENTD/SAID/DEVNC/PRCE docs or hold a wrong price).
-- unit_cost = current average cost (preco_stocks.pmc of the latest year), else last purchase net cost.
-- is_stock_item = 0 for goods that are not physically stocked (software/licences, hosting/cloud, services,
-- freight, taxes, warranty extensions): excluded from reorder and clean-up queries.
-- cost_warning = 'pmc_vs_last_cost' when the average cost and the last purchase cost differ by more than 20%.
DROP VIEW IF EXISTS stock_items;
CREATE VIEW stock_items AS
WITH lp AS (
  SELECT Artigo, data_doc, entidade_codigo, Codigo, serie, numero,
         CAST(Total AS REAL) / CAST(quantidade AS REAL) AS cost,
         ROW_NUMBER() OVER (PARTITION BY Artigo ORDER BY data_doc DESC, _row DESC) AS rn
  FROM lin_compras
  WHERE Codigo IN ('VFT','VFR','VFS','FTINC','FTEXC','VFTC') AND estado_doc <> '1' AND Artigo <> ''
    AND CAST(quantidade AS REAL) > 0 AND CAST(Total AS REAL) > 0),
base AS (
  SELECT a.*, NULLIF(CAST(p.pmc AS REAL),0) AS pmc_v, lp.cost AS lp_cost, lp.data_doc AS lp_date, lp.entidade_codigo AS lp_sup,
         lp.Codigo || ' ' || lp.serie || '/' || lp.numero AS lp_doc,
         aa.min_stock, aa.max_stock, g.descricao AS g_name, f.descricao AS f_name, m.Descricao AS b_name
  FROM Artigos a
  LEFT JOIN Grupos g ON g.Codigo = a.grupo
  LEFT JOIN Familias f ON f.Codigo = a.familia AND f.grupo = a.grupo
  LEFT JOIN Marcas m ON m.Codigo = a.Marca
  LEFT JOIN preco_stocks p ON p.Artigo = a.Codigo AND p.ano = (SELECT MAX(ano) FROM preco_stocks)
  LEFT JOIN lp ON lp.Artigo = a.Codigo AND lp.rn = 1
  LEFT JOIN (SELECT Artigo, MAX(CAST(Stk_Minimo AS REAL)) AS min_stock, MAX(CAST(Stk_Maximo AS REAL)) AS max_stock
             FROM Artigos_Armazem GROUP BY Artigo) aa ON aa.Artigo = a.Codigo)
SELECT b.Codigo AS item_code, trim(b.descricao) AS description,
       CASE b.tipo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee' ELSE b.tipo END AS kind,
       CASE WHEN b.tipo NOT IN ('A','') OR b.Codigo = 'ZZ'
              OR upper(b.grupo) IN ('SOF','IC','SER','POR','TAX','G0001','G0003','PUB','REN','CHIP7')
              OR lower(b.descricao) LIKE '%licen%' OR lower(b.descricao) LIKE '%alojamento%'
              OR lower(b.descricao) LIKE '%subscri%' OR lower(b.descricao) LIKE '%dominio%'
              OR lower(b.descricao) LIKE '%assinatura%' THEN 0 ELSE 1 END AS is_stock_item,
       b.grupo AS group_code, COALESCE(b.g_name, '(sem grupo)') AS group_name,
       b.familia AS family_code, b.f_name AS family_name, b.b_name AS brand_name,
       NULLIF(b.barras,'') AS barcode,
       CAST(b.stock_real AS REAL) AS qty_on_hand,
       CAST(b.stock_disponivel AS REAL) AS qty_available,
       CAST(b.stock_cativo AS REAL) AS qty_reserved,
       CAST(b.stock_encomendas AS REAL) AS qty_on_customer_order,
       CAST(b.stock_requisicoes AS REAL) AS qty_on_supplier_order,
       b.min_stock, b.max_stock,
       COALESCE(b.pmc_v, b.lp_cost, CAST(b.ultc_doc_precoliq AS REAL)) AS unit_cost,
       CASE WHEN b.pmc_v IS NOT NULL THEN 'pmc' WHEN b.lp_cost IS NOT NULL THEN 'last_purchase' ELSE 'item_card' END AS cost_source,
       ROUND(CAST(b.stock_real AS REAL) * COALESCE(b.pmc_v, b.lp_cost, CAST(b.ultc_doc_precoliq AS REAL)), 2) AS stock_value,
       CASE WHEN b.pmc_v IS NOT NULL AND b.lp_cost > 0 AND ABS(b.pmc_v - b.lp_cost) / b.lp_cost > 0.2 THEN 'pmc_vs_last_cost' END AS cost_warning,
       CAST(b.pvp1 AS REAL) AS price_net,
       CASE WHEN b.lp_date > '19000101' THEN date(substr(b.lp_date,1,4)||'-'||substr(b.lp_date,5,2)||'-'||substr(b.lp_date,7,2)) END AS last_purchase_date,
       ROUND(b.lp_cost, 4) AS last_purchase_cost, b.lp_doc AS last_purchase_doc,
       NULLIF(b.lp_sup,'0') AS last_supplier_code, NULLIF(trim(fo.descricao),'') AS last_supplier_name,
       NULLIF(NULLIF(b.for_principal,''),'0') AS main_supplier_code,
       CASE WHEN b.ultv_doc_data > '19000101' THEN date(substr(b.ultv_doc_data,1,4)||'-'||substr(b.ultv_doc_data,5,2)||'-'||substr(b.ultv_doc_data,7,2)) END AS last_sale_date,
       CAST(b.ultv_doc_precoliq AS REAL) AS last_sale_price
FROM base b
LEFT JOIN Fornecedores fo ON fo.Codigo = b.lp_sup;

-- Stock ledger: every line that moved real stock ---------------------------------------------------
-- Rule from gGest `Documentos`: var_stk = 'REAL' and sinal_stk '+' (entry) / '-' (exit); line flag movstock = 1;
-- cancelled sales lines excluded. Sum per item per year equals totais_stocks (2025: 2226 of 2227 items).
-- Year-closing documents (_FE01/_FS01) are NOT here: see stock_year_end for the opening balances.
DROP VIEW IF EXISTS stock_movements;
CREATE VIEW stock_movements AS
WITH d AS (SELECT codigo, CASE sinal_stk WHEN '+' THEN 1 ELSE -1 END AS sg, trim(descricao) AS doc_type_name
           FROM Documentos WHERE var_stk = 'REAL' AND sinal_stk IN ('+','-')),
mv AS (
  SELECT 'sales' AS source, l.Codigo AS doc_type, l.serie, l.numero, l.data_doc, l.data_mov, l.Artigo, l.descricao,
         l.entidade_codigo AS entity_code, CAST(l.quantidade AS REAL) AS qty, CAST(l.pmc AS REAL) AS unit_cost,
         CASE WHEN CAST(l.quantidade AS REAL) <> 0 THEN CAST(l.Total AS REAL) / CAST(l.quantidade AS REAL) END AS unit_price
  FROM lin_vendas l WHERE l.movstock = '1' AND l.estado_doc <> '1'
  UNION ALL
  SELECT 'purchases', l.Codigo, l.serie, l.numero, l.data_doc, l.data_mov, l.Artigo, l.descricao, l.entidade_codigo,
         CAST(l.quantidade AS REAL),
         CASE WHEN CAST(l.quantidade AS REAL) <> 0 THEN CAST(l.Total AS REAL) / CAST(l.quantidade AS REAL) END,
         CASE WHEN CAST(l.quantidade AS REAL) <> 0 THEN CAST(l.Total AS REAL) / CAST(l.quantidade AS REAL) END
  FROM lin_compras l WHERE l.movstock = '1' AND l.estado_doc <> '1'
  UNION ALL
  SELECT 'other_docs', l.Codigo, l.serie, l.numero, l.data_doc, '', l.Artigo, l.descricao, l.entidade_codigo,
         CAST(l.quantidade AS REAL), CAST(l.pmc AS REAL), CAST(l.preco AS REAL)
  FROM lin_outros l WHERE l.movstock = '1'
  UNION ALL
  SELECT 'assembly', l.Codigo, l.serie, l.numero, l.data_doc, l.data_mov, l.Artigo, l.descricao, NULL,
         CAST(l.quantidade AS REAL),
         CASE WHEN l.Codigo = 'PRCE' THEN CAST(l.preco AS REAL) / NULLIF(CAST(l.quantidade AS REAL),0) ELSE CAST(l.pmc AS REAL) END,
         CASE WHEN l.Codigo = 'PRCE' THEN CAST(l.preco AS REAL) / NULLIF(CAST(l.quantidade AS REAL),0) ELSE CAST(l.preco AS REAL) END
  FROM lin_producao l WHERE l.mov_stock = '1'
  UNION ALL
  SELECT 'stock_docs', l.Codigo, l.serie, l.numero, l.data_doc, l.data_mov, l.Artigo, l.descricao, NULL,
         CAST(l.quantidade AS REAL), CAST(l.pmc AS REAL), CAST(l.preco AS REAL)
  FROM Lin_Stocks l WHERE l.mov_stock = '1' AND substr(l.Codigo,1,1) <> '_')
SELECT mv.doc_type || ' ' || mv.serie || '/' || mv.numero AS doc_id, mv.doc_type, d.doc_type_name, mv.source,
       CASE
         WHEN mv.doc_type IN ('FT','FR','FS','FTGOL','VIAT','ND') THEN 'sale'
         WHEN mv.doc_type IN ('NC','NCP','NCCIR') THEN 'sale_return'
         WHEN mv.doc_type = 'FRCIN' THEN 'internal_use'
         WHEN mv.doc_type = 'FTPTC' THEN 'sponsorship'
         WHEN mv.doc_type IN ('VFT','VFR','VFS','FTINC','FTEXC','FADIA','VND','VFTC') THEN 'purchase'
         WHEN mv.doc_type IN ('DEVNC','VNC','VNCP','NCADI','VNCC') THEN 'purchase_return'
         WHEN mv.doc_type = 'PRCE' THEN 'assembly_in'
         WHEN mv.doc_type = 'PRCS' THEN 'assembly_out'
         WHEN mv.doc_type IN ('ENTD','STKE','INVE','TRFAE') THEN 'adjustment_in'
         WHEN mv.doc_type IN ('SAID','STKS','INVS','TRFAS') THEN 'adjustment_out'
         WHEN mv.doc_type = 'SSTKA' THEN 'write_off'
         WHEN mv.doc_type = 'CI' THEN 'internal_use'
         WHEN mv.doc_type = 'CG' THEN 'warranty_use'
         WHEN mv.doc_type IN ('CONOF','CSOF') THEN 'workshop_use'
         WHEN mv.doc_type IN ('EMPTC','EPTTE') THEN 'loan_out'
         ELSE 'other' END AS movement_kind,
       date(substr(mv.data_doc,1,4)||'-'||substr(mv.data_doc,5,2)||'-'||substr(mv.data_doc,7,2)) AS doc_date,
       CAST(substr(mv.data_doc,1,4) AS INTEGER) AS year, substr(mv.data_doc,1,4)||'-'||substr(mv.data_doc,5,2) AS month,
       mv.Artigo AS item_code, trim(mv.descricao) AS description,
       NULLIF(NULLIF(mv.entity_code,''),'0') AS entity_code,
       CASE WHEN mv.source IN ('sales','other_docs') THEN 'customer' WHEN mv.source = 'purchases' THEN 'supplier' END AS entity_kind,
       d.sg AS direction, d.sg * mv.qty AS qty, mv.unit_cost, ROUND(d.sg * mv.qty * mv.unit_cost, 2) AS value_at_cost,
       mv.unit_price
FROM mv JOIN d ON d.codigo = mv.doc_type
WHERE mv.Artigo <> '' AND mv.data_doc > '19000101';

-- Year-end stock per item (gGest year-closing opening balance _FE01 of the next year) -------------
-- year = the year that closed (e.g. 2025 = stock on 2025-12-31). Matches the AT inventory (InvAT_*) totals.
DROP VIEW IF EXISTS stock_year_end;
CREATE VIEW stock_year_end AS
SELECT CAST(l.ano AS INTEGER) - 1 AS year, l.Artigo AS item_code, trim(l.descricao) AS description,
       COALESCE(g.descricao, '(sem grupo)') AS group_name,
       CAST(l.quantidade AS REAL) AS qty, CAST(l.pmc AS REAL) AS unit_cost,
       ROUND(CAST(l.quantidade AS REAL) * CAST(l.pmc AS REAL), 2) AS stock_value
FROM Lin_Stocks l
LEFT JOIN Artigos a ON a.Codigo = l.Artigo
LEFT JOIN Grupos g ON g.Codigo = a.grupo
WHERE l.Codigo = '_FE01';

-- Assembly (PC building): one row per assembly order --------------------------------------------
-- gGest "Produção (composição)": PRCE = entry of the built item, PRCS = exit of its components (same serie/numero/ano).
-- PRCE.preco holds the TOTAL cost of the batch (= sum of PRCS qty*preco), not a unit cost. qty 0 = built item not stocked.
DROP VIEW IF EXISTS assembly_orders;
CREATE VIEW assembly_orders AS
SELECT 'PRC ' || e.serie || '/' || e.numero AS assembly_id, e.serie, CAST(e.numero AS INTEGER) AS number, e.ano AS series_year,
       date(substr(e.data_doc,1,4)||'-'||substr(e.data_doc,5,2)||'-'||substr(e.data_doc,7,2)) AS assembled_on,
       CAST(substr(e.data_doc,1,4) AS INTEGER) AS year,
       e.Artigo AS item_code, trim(e.descricao) AS description, CAST(e.quantidade AS REAL) AS qty,
       ROUND(CAST(e.preco AS REAL) / NULLIF(CAST(e.quantidade AS REAL),0), 2) AS unit_cost,  -- PRCE.preco is the batch total
       CAST(e.preco AS REAL) AS total_cost,
       (SELECT COUNT(*) FROM lin_producao c WHERE c.Codigo = 'PRCS' AND c.serie = e.serie AND c.numero = e.numero AND c.ano = e.ano AND c.Artigo NOT IN ('','ZZ')) AS component_lines,
       (SELECT ROUND(SUM(CAST(c.quantidade AS REAL) * CAST(c.preco AS REAL)),2) FROM lin_producao c WHERE c.Codigo = 'PRCS' AND c.serie = e.serie AND c.numero = e.numero AND c.ano = e.ano) AS components_cost
FROM lin_producao e
WHERE e.Codigo = 'PRCE' AND e.Artigo <> '';

DROP VIEW IF EXISTS assembly_components;
CREATE VIEW assembly_components AS
SELECT 'PRC ' || c.serie || '/' || c.numero AS assembly_id, c.ano AS series_year,
       date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS assembled_on,
       CAST(substr(c.data_doc,1,4) AS INTEGER) AS year,
       c.Artigo AS item_code, trim(c.descricao) AS description, COALESCE(g.descricao, '(sem grupo)') AS group_name,
       CAST(c.quantidade AS REAL) AS qty, CAST(c.preco AS REAL) AS unit_cost,
       ROUND(CAST(c.quantidade AS REAL) * CAST(c.preco AS REAL), 2) AS total_cost
FROM lin_producao c
LEFT JOIN Artigos a ON a.Codigo = c.Artigo
LEFT JOIN Grupos g ON g.Codigo = a.grupo
WHERE c.Codigo = 'PRCS' AND c.Artigo NOT IN ('','ZZ');

-- Purchase lines (supplier invoices / credit notes, line level) -----------------------------------
-- unit_cost_net = line Total / qty (after line discounts, net of VAT). Returns/credit notes negative.
DROP VIEW IF EXISTS stock_purchase_lines;
CREATE VIEW stock_purchase_lines AS
SELECT l.Codigo || ' ' || l.serie || '/' || l.numero AS doc_id, l.Codigo AS doc_type,
       date(substr(l.data_doc,1,4)||'-'||substr(l.data_doc,5,2)||'-'||substr(l.data_doc,7,2)) AS doc_date,
       CAST(substr(l.data_doc,1,4) AS INTEGER) AS year, substr(l.data_doc,1,4)||'-'||substr(l.data_doc,5,2) AS month,
       l.entidade_codigo AS supplier_code, trim(c.entidade_descricao) AS supplier_name,
       CASE WHEN c.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       CASE WHEN l.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN 1 ELSE 0 END AS is_return,
       NULLIF(l.Artigo,'') AS item_code, trim(l.descricao) AS description,
       COALESCE(g.descricao, '(sem grupo)') AS group_name,
       CASE l.tipo_artigo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee' WHEN 'S' THEN 'service' ELSE 'text' END AS line_kind,
       CASE WHEN l.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(l.quantidade AS REAL) AS qty,
       CAST(l.preco AS REAL) AS unit_price_list, CAST(l.desc_lin_per1 AS REAL) AS discount_pct,
       CASE WHEN CAST(l.quantidade AS REAL) <> 0 THEN ROUND(CAST(l.Total AS REAL) / CAST(l.quantidade AS REAL), 4) END AS unit_cost_net,
       CASE WHEN l.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(l.Total AS REAL) AS net
FROM lin_compras l
LEFT JOIN cab_compras c ON c.Codigo = l.Codigo AND c.serie = l.serie AND c.numero = l.numero AND c.ano = l.ano
LEFT JOIN Artigos a ON a.Codigo = l.Artigo
LEFT JOIN Grupos g ON g.Codigo = a.grupo
WHERE l.data_doc > '19000101';

-- Serial numbers: every document line that moved a serial number ---------------------------------
-- From lin_mov_series. Purchase docs: entity = supplier; sales/repairs/quotes: entity = customer.
DROP VIEW IF EXISTS serial_movements;
CREATE VIEW serial_movements AS
SELECT trim(s.Serie_Artigo) AS serial_number, s.Artigo AS item_code, trim(a.descricao) AS item_description,
       s.Codigo AS doc_type, s.Codigo || ' ' || s.Serie || '/' || s.Numero AS doc_id,
       date(substr(s.Data,1,4)||'-'||substr(s.Data,5,2)||'-'||substr(s.Data,7,2)) AS doc_date,
       CASE WHEN s.Codigo IN ('VFT','VFR','VFS','FTINC','FTEXC','DEVNC','VNC','VNCP') THEN 'supplier'
            WHEN s.Codigo IN ('PRCE','PRCS','SAID','ENTD','CI','CG','SSTKA','SCV','STKS') THEN 'internal'
            ELSE 'customer' END AS entity_kind,
       NULLIF(s.Entidade,'0') AS entity_code,
       CASE WHEN s.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       ROUND(CASE WHEN ast.Tipo_Garantia = '2' THEN CAST(ast.Prazo_Garantia AS REAL) / 12 ELSE CAST(ast.Prazo_Garantia AS REAL) END, 2) AS warranty_years,  -- Tipo_Garantia 2 = months
       ast.Estado AS serial_status_flag  -- gGest registry flag, not a reliable in-stock indicator (see serial_registry for warranty)
FROM lin_mov_series s
LEFT JOIN Artigos a ON a.Codigo = s.Artigo
LEFT JOIN Artigos_series ast ON ast.Codigo = s.Artigo AND ast.Serie = s.Serie_Artigo
WHERE trim(s.Serie_Artigo) <> '';

-- Supplier RMAs (defective items sent back to the supplier under warranty) -------------------------
-- From assTec_RMA. Contact fields (phone/e-mail) and fault texts deliberately left out.
DROP VIEW IF EXISTS supplier_rmas;
CREATE VIEW supplier_rmas AS
SELECT CAST(r.numero AS INTEGER) AS rma_number,
       CASE WHEN r.data_abertura > '19000101' THEN date(substr(r.data_abertura,1,4)||'-'||substr(r.data_abertura,5,2)||'-'||substr(r.data_abertura,7,2)) END AS opened_on,
       CASE WHEN r.envio_data > '19000101' THEN date(substr(r.envio_data,1,4)||'-'||substr(r.envio_data,5,2)||'-'||substr(r.envio_data,7,2)) END AS sent_on,
       CASE WHEN r.rececao_data > '19000101' THEN date(substr(r.rececao_data,1,4)||'-'||substr(r.rececao_data,5,2)||'-'||substr(r.rececao_data,7,2)) END AS received_back_on,
       CASE WHEN r.resolFor_doc_data > '19000101' THEN date(substr(r.resolFor_doc_data,1,4)||'-'||substr(r.resolFor_doc_data,5,2)||'-'||substr(r.resolFor_doc_data,7,2)) END AS supplier_resolved_on,
       r.estado AS status_code,
       NULLIF(r.doc_compra_entidade,'0') AS supplier_code, f.supplier_name,
       CASE WHEN r.doc_compra_data > '19000101' THEN date(substr(r.doc_compra_data,1,4)||'-'||substr(r.doc_compra_data,5,2)||'-'||substr(r.doc_compra_data,7,2)) END AS purchased_on,
       NULLIF(r.cliente_codigo,'0') AS customer_code,
       NULLIF(r.artigo,'') AS item_code, NULLIF(r.marca,'') AS brand_code,
       CAST(r.envio_transp_custos AS REAL) AS shipping_cost,
       NULLIF(r.resolFor_acao,'0') AS supplier_action_code, NULLIF(r.resolCli_acao,'0') AS customer_action_code,
       CASE WHEN r.origem_int_codigo <> '' THEN r.origem_int_codigo || ' ' || r.origem_int_serie || '/' || r.origem_int_numero END AS origin_repair_id
FROM assTec_RMA r
LEFT JOIN (SELECT Codigo, trim(descricao) AS supplier_name FROM Fornecedores) f ON f.Codigo = r.doc_compra_entidade;

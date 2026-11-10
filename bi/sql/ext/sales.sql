-- Sales domain extension: quotes / pro-formas / orders (cab_outros, module OTC), delivery notes (cab_guias,
-- module GIC) and the online-shop catalogue (Ecom_Artigos). Depends only on core views and raw gGest tables.
-- Apply with: uv run ggest build-views --file bi/sql/ext/sales.sql
--
-- gGest "outros documentos para clientes" (cab_outros/lin_outros), by doc type (see doc_types.fiscal_type):
--   ORC quote (orçamento, OR) · FPF pro-forma invoice (PF) · ENC customer order (encomenda, NE)
--   ET / EPTTE / EMPTC technical loan (equipment lent to a customer) · CONOF / CSOF workshop consumption
-- None of them is revenue. Conversion into an invoice is recorded on the invoice line (lin_vendas.origem_*),
-- on a delivery note line (lin_guias.origem_*) and as the converted quantity on the quote line
-- (lin_outros.convertido) — but the shop usually retypes the invoice, so links exist for only a small minority of quotes.
-- quote_outcomes therefore adds a heuristic: same customer invoiced within 60 days.

-- One row per "other" customer document ----------------------------------------------------------------
DROP VIEW IF EXISTS quote_docs;
CREATE VIEW quote_docs AS
SELECT o.Codigo || ' ' || o.serie || '/' || o.numero AS doc_id,
       o.Codigo AS doc_type, dt.description AS doc_type_name,
       CASE o.Codigo WHEN 'ORC' THEN 'quote' WHEN 'FPF' THEN 'proforma' WHEN 'ENC' THEN 'order'
            WHEN 'ET' THEN 'loan' WHEN 'EPTTE' THEN 'loan' WHEN 'EMPTC' THEN 'loan'
            WHEN 'CONOF' THEN 'workshop_consumption' WHEN 'CSOF' THEN 'workshop_consumption'
            ELSE 'other' END AS doc_kind,
       o.serie AS series, CAST(o.numero AS INTEGER) AS number,
       date(substr(o.data_doc,1,4)||'-'||substr(o.data_doc,5,2)||'-'||substr(o.data_doc,7,2)) AS doc_date,
       CAST(substr(o.data_doc,1,4) AS INTEGER) AS year,
       substr(o.data_doc,1,4)||'-'||substr(o.data_doc,5,2) AS month,
       CASE WHEN o.data_venc > o.data_doc THEN
            date(substr(o.data_venc,1,4)||'-'||substr(o.data_venc,5,2)||'-'||substr(o.data_venc,7,2)) END AS valid_until,
       o.entidade_codigo AS customer_code, trim(o.entidade_descricao) AS customer_name,
       NULLIF(trim(o.entidade_contribuinte),'') AS customer_nif,
       CASE WHEN o.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       NULLIF(trim(o.motivo_anulacao),'') AS cancel_reason,
       CAST(o.total_documento AS REAL) - CAST(o.Total_iva AS REAL) AS net,
       CAST(o.Total_iva AS REAL) AS vat,
       CAST(o.total_documento AS REAL) AS gross,
       CAST(o.Total_mercadoria AS REAL) AS goods_net,
       CAST(o.Total_servicos AS REAL) AS services_net,
       CAST(o.total_descontos_lin AS REAL) + CAST(o.total_descontos_cab AS REAL) AS discount,
       COALESCE(n.line_count, 0) AS line_count,              -- item lines (products/services/fees), text lines excluded
       CAST(o.numero_itens AS REAL) AS total_qty,            -- gGest numero_itens = sum of quantities, NOT a line count
       NULLIF(trim(o.referencia),'') AS reference,
       o.inserido_util AS created_by_user
FROM cab_outros o
LEFT JOIN doc_types dt ON dt.doc_type = o.Codigo
LEFT JOIN (SELECT Codigo, serie, numero, COUNT(*) AS line_count FROM lin_outros
           WHERE tipo_artigo IN ('A','E','F') GROUP BY 1, 2, 3) n
  ON n.Codigo = o.Codigo AND n.serie = o.serie AND n.numero = o.numero
WHERE o.data_doc <> '';

-- One row per line of those documents ------------------------------------------------------------------
DROP VIEW IF EXISTS quote_lines;
CREATE VIEW quote_lines AS
SELECT l.Codigo || ' ' || l.serie || '/' || l.numero AS doc_id, l.Codigo AS doc_type,
       date(substr(l.data_doc,1,4)||'-'||substr(l.data_doc,5,2)||'-'||substr(l.data_doc,7,2)) AS doc_date,
       CAST(substr(l.data_doc,1,4) AS INTEGER) AS year,
       l.entidade_codigo AS customer_code,
       CAST(l.linha AS INTEGER) AS line_no,
       NULLIF(trim(l.Artigo),'') AS item_code, trim(l.descricao) AS item_description,
       CASE l.tipo_artigo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee' ELSE 'text' END AS line_kind,
       a.grupo AS group_code, g.descricao AS group_name, a.familia AS family_code, f.descricao AS family_name,
       CAST(l.quantidade AS REAL) AS qty,
       CAST(l.convertido AS REAL) AS converted_qty,       -- quantity already carried into an invoice / delivery note
       CAST(l.preco AS REAL) AS unit_price_net,
       CAST(l.Total AS REAL) AS net,
       -- cost: pmc on the line (only recorded on loans/workshop docs, ~never on quotes), else the item's current
       -- last purchase net price (not for the generic ZZ item); 0 = unknown
       CASE WHEN CAST(l.pmc AS REAL) > 0 THEN CAST(l.pmc AS REAL)
            WHEN upper(l.Artigo) <> 'ZZ' AND CAST(a.ultc_doc_precoliq AS REAL) > 0 THEN CAST(a.ultc_doc_precoliq AS REAL)
            ELSE 0 END AS unit_cost,
       CASE WHEN CAST(l.pmc AS REAL) > 0 THEN 'pmc'
            WHEN upper(l.Artigo) <> 'ZZ' AND CAST(a.ultc_doc_precoliq AS REAL) > 0 THEN 'last_purchase_now'
            ELSE 'unknown' END AS cost_source,
       CASE WHEN l.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled
FROM lin_outros l
LEFT JOIN Artigos a ON a.Codigo = l.Artigo
LEFT JOIN Grupos g ON g.Codigo = a.grupo
LEFT JOIN Familias f ON f.Codigo = a.familia AND f.grupo = a.grupo;

-- Outcome of each quote / pro-forma / order (not cancelled) --------------------------------------------
-- linked_invoice_id: first invoice whose lines reference the document (directly or through a delivery note).
-- invoiced_60d_net: net sales (sales_facts) to the same customer from the document date to 60 days later.
-- outcome: 'converted_linked' (explicit link / converted qty) · 'likely_won' (same customer invoiced >= 50% of the
-- quote value within 60 days) · 'open' (still valid: valid_until >= today when set, else <= 60 days old; not won)
-- · 'partial' (expired, invoiced something but < 50%) · 'not_won' (expired, nothing invoiced). Walk-in customers ("consumidor final") cannot be matched (very few quotes use them).
DROP VIEW IF EXISTS quote_outcomes;
CREATE VIEW quote_outcomes AS
WITH snap AS MATERIALIZED (SELECT max(doc_date) AS today FROM sales_facts),
links AS MATERIALIZED (
  SELECT src_id, min(target_id) AS target_id FROM (
    SELECT origem_codigo || ' ' || origem_serie || '/' || origem_numero AS src_id,
           Codigo || ' ' || serie || '/' || numero AS target_id
    FROM lin_vendas WHERE origem_codigo IN ('ORC','FPF','ENC')
    UNION ALL
    SELECT g.origem_codigo || ' ' || g.origem_serie || '/' || g.origem_numero,
           COALESCE(v.Codigo || ' ' || v.serie || '/' || v.numero, g.Codigo || ' ' || g.serie || '/' || g.numero)
    FROM lin_guias g
    LEFT JOIN (SELECT DISTINCT Codigo, serie, numero, origem_codigo, origem_serie, origem_numero FROM lin_vendas
               WHERE origem_codigo = 'GTC') v
      ON v.origem_codigo = g.Codigo AND v.origem_serie = g.serie AND v.origem_numero = g.numero
    WHERE g.origem_codigo IN ('ORC','FPF','ENC')) GROUP BY src_id),
conv AS MATERIALIZED (SELECT Codigo || ' ' || serie || '/' || numero AS doc_id, sum(CAST(convertido AS REAL)) AS converted_qty
         FROM lin_outros WHERE Codigo IN ('ORC','FPF','ENC') GROUP BY 1),
q AS MATERIALIZED (SELECT * FROM quote_docs WHERE doc_kind IN ('quote','proforma','order') AND is_cancelled = 0),
sold AS MATERIALIZED (
  SELECT q.doc_id, sum(f.net) AS invoiced_60d_net, min(CASE WHEN f.net > 0 THEN f.doc_date END) AS first_invoice_date
  FROM q JOIN sales_facts f ON f.customer_code = q.customer_code
       AND f.doc_date >= q.doc_date AND f.doc_date <= date(q.doc_date, '+60 days')
  GROUP BY q.doc_id),
base AS (
  SELECT q.*, k.target_id AS linked_doc_id, COALESCE(c.converted_qty, 0) AS converted_qty,
         COALESCE(s.invoiced_60d_net, 0) AS invoiced_60d_net, s.first_invoice_date,
         (SELECT today FROM snap) AS today,
         CAST(julianday((SELECT today FROM snap)) - julianday(q.doc_date) AS INTEGER) AS age_days
  FROM q LEFT JOIN conv c ON c.doc_id = q.doc_id
         LEFT JOIN links k ON k.src_id = q.doc_id
         LEFT JOIN sold s ON s.doc_id = q.doc_id)
SELECT doc_id, doc_type, doc_kind, doc_date, year, month, valid_until, customer_code, customer_name, customer_nif,
       net, gross, line_count, total_qty, created_by_user, age_days,
       CASE WHEN valid_until IS NOT NULL THEN CAST(julianday(valid_until) - julianday(today) AS INTEGER) END AS valid_days_left,
       linked_doc_id, converted_qty,
       invoiced_60d_net, first_invoice_date,
       CASE WHEN first_invoice_date IS NOT NULL THEN CAST(julianday(first_invoice_date) - julianday(doc_date) AS INTEGER) END AS days_to_invoice,
       CASE WHEN linked_doc_id IS NOT NULL OR converted_qty > 0 THEN 'converted_linked'
            WHEN net > 0 AND invoiced_60d_net >= 0.5 * net THEN 'likely_won'
            WHEN (valid_until IS NOT NULL AND valid_until >= today) OR (valid_until IS NULL AND age_days <= 60) THEN 'open'
            WHEN invoiced_60d_net > 0 THEN 'partial'
            ELSE 'not_won' END AS outcome
FROM base;

-- Delivery / transport notes to customers (guias) ------------------------------------------------------
-- GTC transport note (most), GTCG global, GRC remittance, GDC return, GCC consignment, GMA own assets, NGT (old).
-- invoiced_by: invoice whose lines reference the note. Many notes only accompany goods already invoiced (their
-- text line quotes the invoice: refers_to_invoice = 1) or equipment sent for repair, so "not linked" is a list
-- to review, not money lost.
DROP VIEW IF EXISTS delivery_notes;
CREATE VIEW delivery_notes AS
WITH inv AS (SELECT origem_codigo || ' ' || origem_serie || '/' || origem_numero AS src_id,
                    min(Codigo || ' ' || serie || '/' || numero) AS invoice_id
             FROM lin_vendas WHERE origem_codigo IN ('GTC','GTCG','GRC','GDC','GCC','GMA','NGT') GROUP BY 1),
ln AS (SELECT Codigo || ' ' || serie || '/' || numero AS doc_id,
              max(CASE WHEN upper(descricao) LIKE '%FATURA%' OR upper(descricao) LIKE '%FACTURA%'
                        OR descricao LIKE 'FT %' OR descricao LIKE 'FR %' THEN 1 ELSE 0 END) AS refers_to_invoice,
              max(CASE WHEN origem_codigo <> '' THEN origem_codigo || ' ' || origem_serie || '/' || origem_numero END) AS origin_doc_id,
              sum(CAST(convertido AS REAL)) AS converted_qty, sum(CAST(quantidade AS REAL)) AS qty,
              sum(tipo_artigo IN ('A','E','F')) AS line_count
       FROM lin_guias GROUP BY 1)
SELECT g.Codigo || ' ' || g.serie || '/' || g.numero AS doc_id, g.Codigo AS doc_type, dt.description AS doc_type_name,
       g.serie AS series, CAST(g.numero AS INTEGER) AS number,
       date(substr(g.data_doc,1,4)||'-'||substr(g.data_doc,5,2)||'-'||substr(g.data_doc,7,2)) AS doc_date,
       CAST(substr(g.data_doc,1,4) AS INTEGER) AS year,
       g.entidade_codigo AS customer_code, trim(g.entidade_descricao) AS customer_name,
       CASE WHEN g.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       CAST(g.total_documento AS REAL) - CAST(g.Total_iva AS REAL) AS net,
       CAST(g.total_documento AS REAL) AS gross,
       COALESCE(ln.line_count, 0) AS line_count,
       NULLIF(trim(g.atcud),'') AS atcud,
       ln.origin_doc_id, ln.qty, ln.converted_qty, COALESCE(ln.refers_to_invoice, 0) AS refers_to_invoice,
       inv.invoice_id AS invoiced_by,
       CASE WHEN inv.invoice_id IS NOT NULL OR ln.converted_qty > 0 THEN 'invoiced'
            WHEN ln.refers_to_invoice = 1 THEN 'after_invoice'
            ELSE 'not_linked' END AS billing_status,
       g.inserido_util AS created_by_user
FROM cab_guias g
LEFT JOIN doc_types dt ON dt.doc_type = g.Codigo
LEFT JOIN inv ON inv.src_id = g.Codigo || ' ' || g.serie || '/' || g.numero
LEFT JOIN ln ON ln.doc_id = g.Codigo || ' ' || g.serie || '/' || g.numero
WHERE g.data_doc <> '';

-- Online shop catalogue (gGest e-commerce sync: Ecom_Artigos, one row per published item) --------------
-- Prices/stock are not stored here (Preco_Venda is 0): take them from items. Synced since 2026.
DROP VIEW IF EXISTS online_items;
CREATE VIEW online_items AS
SELECT e.Codigo AS item_code, trim(e.Nome) AS online_name, e.Loja AS shop,
       CASE WHEN e.Ativo = '1' THEN 1 ELSE 0 END AS is_active,
       CASE WHEN e.Visivel = '1' THEN 1 ELSE 0 END AS is_visible,
       CASE WHEN e.Disponivel_Encomenda = '1' THEN 1 ELSE 0 END AS orderable,
       CASE WHEN e.Mostrar_Preco = '1' THEN 1 ELSE 0 END AS shows_price,
       e.Marca AS brand_code, NULLIF(e.Codigo_EAN13,'') AS ean,
       i.description, i.group_name, i.family_name, i.price_net, i.stock_qty, i.last_purchase_price,
       CASE WHEN e.alterado_data > '19000000' THEN date(substr(e.alterado_data,1,4)||'-'||substr(e.alterado_data,5,2)||'-'||substr(e.alterado_data,7,2)) END AS synced_on
FROM Ecom_Artigos e
LEFT JOIN items i ON i.item_code = e.Codigo;

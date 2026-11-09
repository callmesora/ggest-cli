-- name: customers_timeline
-- description: Latest interactions with one customer, newest first: invoices/credit notes (net, main item), quotes (net), repair orders (equipment, brand/model, status, value on the order; never the fault text) and agenda appointments. customer = customer code or NIF; merge_nif = 1 includes the other records with the same NIF. kind = all | sale | quote | repair | appointment
-- params: customer=, merge_nif=1, kind=all, limit=30
WITH t AS MATERIALIZED (
  SELECT d.customer_code FROM customer_dim d
  WHERE d.customer_code = :customer OR d.nif_clean = upper(replace(:customer, ' ', ''))
     OR (:merge_nif = 1 AND d.entity_key = (SELECT entity_key FROM customer_dim WHERE customer_code = :customer))),
sl AS (
  SELECT doc_id, item_description, ROW_NUMBER() OVER (PARTITION BY doc_id ORDER BY abs(net) DESC) AS rn
  FROM sales_facts WHERE customer_code IN (SELECT customer_code FROM t)),
ev AS (
  SELECT d.doc_date AS event_date, 'sale' AS kind, d.doc_id AS reference, d.customer_code,
         ROUND(d.net, 2) AS net, sl.item_description AS detail, d.doc_type_name AS status
  FROM sales_docs d LEFT JOIN sl ON sl.doc_id = d.doc_id AND sl.rn = 1
  WHERE d.customer_code IN (SELECT customer_code FROM t) AND d.is_cancelled = 0 AND d.is_internal = 0
  UNION ALL
  SELECT date(substr(o.data_doc,1,4)||'-'||substr(o.data_doc,5,2)||'-'||substr(o.data_doc,7,2)), 'quote',
         o.Codigo || ' ' || o.serie || '/' || o.numero, o.entidade_codigo,
         ROUND(CAST(o.total_documento AS REAL) - CAST(o.Total_iva AS REAL), 2), NULLIF(trim(o.referencia), ''), NULL
  FROM cab_outros o WHERE o.Codigo = 'ORC' AND o.estado_doc <> '1' AND o.entidade_codigo IN (SELECT customer_code FROM t)
  UNION ALL
  SELECT r.opened_on, 'repair', r.repair_id, r.customer_code, r.quoted_net,
         trim(COALESCE(r.equipment_type,'') || ' ' || COALESCE(r.brand_name,'') || ' ' || COALESCE(r.model,'')), r.status
  FROM repairs r WHERE r.customer_code IN (SELECT customer_code FROM t)
  UNION ALL
  SELECT date(a.starts_at), 'appointment', 'AGENDA ' || a.task_id, a.customer_code, NULL,
         COALESCE(a.task_type, '') || ': ' || COALESCE(a.title, ''), a.status
  FROM customer_appointments a WHERE a.customer_code IN (SELECT customer_code FROM t))
SELECT * FROM ev WHERE :kind = 'all' OR kind = :kind
ORDER BY event_date DESC, reference DESC LIMIT :limit

-- name: repairs_unbilled_orders
-- description: Repair orders with no value - possible unbilled work. An order "has value" when the value typed on the order (header total, net) > 0. grain=year: orders, with_value, no_value (+%), no_value orders split by whether the technician described work done (work_text) or not, mentioning 'garantia' or ' rma' in the technician notes, invoiced from the order (OSA conversion, 2024+) and with a labour invoice (item ASSISTENCIA + travel/remote, family-independent) to the same customer within window_days after opening. grain=list: the no-value orders of the period (closed or ready) with no OSA invoice and no labour invoice in the window - candidates to check/charge; flags only, no free text. Walk-in customer records are kept (they cannot be matched to later invoices, so treat their labour flag with care).
-- params: start=last_year_start, end=today, grain=year, window_days=45, limit=200
WITH o AS (
  SELECT r.repair_id, r.series_year, r.year, r.opened_on, r.status_code, r.customer_code, r.customer_name,
         COALESCE(r.equipment_type, r.equipment_type_code) AS equipment, r.quoted_net,
         CASE WHEN COALESCE(r.quoted_net, 0) > 0 THEN 1 ELSE 0 END AS has_value,
         CASE WHEN length(COALESCE(r.work_done, '')) >= 5 THEN 1 ELSE 0 END AS work_text,
         CASE WHEN lower(COALESCE(r.diagnosis, '') || ' ' || COALESCE(r.work_done, '')) LIKE '%garantia%'
                OR lower(COALESCE(r.diagnosis, '') || ' ' || COALESCE(r.work_done, '')) LIKE '% rma%' THEN 1 ELSE 0 END AS warranty_rma
  FROM repairs r WHERE r.opened_on BETWEEN :start AND :end),
inv AS MATERIALIZED (SELECT DISTINCT origin_doc_id FROM sales_facts WHERE origin_doc_type = 'OSA'),
f AS (
  SELECT o.*,
         o.repair_id IN (SELECT origin_doc_id FROM inv) AS invoiced_from_order,
         EXISTS (SELECT 1 FROM sales_facts s WHERE s.customer_code = o.customer_code
                   AND s.doc_date BETWEEN o.opened_on AND date(o.opened_on, '+' || :window_days || ' days')
                   AND (upper(s.item_code) IN ('ASSISTENCIA','DESLOCACAO') OR upper(s.item_code) LIKE '%REMOT%')) AS labour_invoice
  FROM o)
SELECT * FROM (
  SELECT CAST(year AS TEXT) AS period, NULL AS repair_id, NULL AS opened_on, NULL AS status_code, NULL AS customer_code,
         NULL AS customer_name, NULL AS equipment,
         COUNT(*) AS orders, SUM(has_value) AS with_value, SUM(1 - has_value) AS no_value,
         ROUND(100.0 * SUM(1 - has_value) / COUNT(*), 1) AS pct_no_value,
         SUM(has_value = 0 AND work_text = 1) AS no_value_with_work_text, SUM(has_value = 0 AND work_text = 0) AS no_value_no_work_text,
         SUM(has_value = 0 AND warranty_rma = 1) AS no_value_warranty_rma,
         SUM(has_value = 0 AND invoiced_from_order) AS no_value_invoiced_from_order,
         SUM(has_value = 0 AND labour_invoice) AS no_value_labour_invoice_in_window
  FROM f WHERE :grain = 'year' GROUP BY year
  UNION ALL
  SELECT 'list', repair_id, opened_on, status_code, customer_code, customer_name, equipment,
         NULL, NULL, NULL, NULL, work_text, NULL, warranty_rma, invoiced_from_order, labour_invoice
  FROM f WHERE :grain = 'list' AND has_value = 0 AND status_code IN ('FEC','PRO') AND NOT invoiced_from_order AND NOT labour_invoice)
ORDER BY period, opened_on DESC
LIMIT :limit

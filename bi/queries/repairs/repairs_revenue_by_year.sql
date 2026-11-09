-- name: repairs_revenue_by_year
-- description: How repairs make money, per year (sales exist from 2017). labour_* = invoiced repair labour (item ASSISTENCIA 'Assistencia Tecnica - Mao de Obra' + technician travel/remote items; labour has no recorded cost, so it is ~100% gross margin) and its share of total company net sales and gross margin. osa_* = invoices converted from a repair order (origin_doc_type OSA; only used since 2024-03, so before that repairs were invoiced on separate documents): count, net, labour vs parts split and parts margin. order_* = value typed on the repair orders themselves (Lin_Assistec: parts + labour quoted/charged on the order; ~half of orders have no value = warranty, no repair, quote refused or not recorded).
-- params: start_year=2017, end_year=2026
WITH y AS (SELECT year, COUNT(*) AS repairs FROM repairs WHERE year BETWEEN :start_year AND :end_year GROUP BY year),
s AS (
  SELECT year, SUM(net) AS total_net, SUM(margin) AS total_margin,
         SUM(CASE WHEN item_code IN ('ASSISTENCIA','Remoto','domicilio') OR family_name LIKE 'DESLOCA%' THEN net ELSE 0 END) AS labour_net,
         COUNT(DISTINCT CASE WHEN item_code IN ('ASSISTENCIA','Remoto','domicilio') OR family_name LIKE 'DESLOCA%' THEN doc_id END) AS labour_invoices,
         COUNT(DISTINCT CASE WHEN origin_doc_type = 'OSA' THEN origin_doc_id END) AS osa_orders_invoiced,
         SUM(CASE WHEN origin_doc_type = 'OSA' THEN net ELSE 0 END) AS osa_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' AND line_kind = 'service' THEN net ELSE 0 END) AS osa_labour_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' AND line_kind = 'product' THEN net ELSE 0 END) AS osa_parts_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' AND line_kind = 'product' THEN margin ELSE 0 END) AS osa_parts_margin
  FROM sales_facts WHERE year BETWEEN :start_year AND :end_year GROUP BY year),
o AS (
  SELECT year, COUNT(DISTINCT repair_id) AS orders_with_value, SUM(net) AS order_lines_net,
         SUM(CASE WHEN line_kind = 'service' OR item_code = 'ASSISTENCIA' THEN net ELSE 0 END) AS order_labour_net,
         SUM(CASE WHEN line_kind = 'product' AND COALESCE(item_code, '') <> 'ASSISTENCIA' THEN net ELSE 0 END) AS order_parts_net
  FROM repair_lines WHERE year BETWEEN :start_year AND :end_year AND net <> 0 GROUP BY year)
SELECT y.year, y.repairs,
       ROUND(s.labour_net, 2) AS labour_net, s.labour_invoices,
       ROUND(s.labour_net / NULLIF(s.labour_invoices, 0), 2) AS labour_per_invoice,
       ROUND(100.0 * s.labour_net / NULLIF(s.total_net, 0), 1) AS labour_pct_of_sales,
       ROUND(100.0 * s.labour_net / NULLIF(s.total_margin, 0), 1) AS labour_pct_of_gross_margin,
       s.osa_orders_invoiced, ROUND(s.osa_net, 2) AS osa_net, ROUND(s.osa_labour_net, 2) AS osa_labour_net,
       ROUND(s.osa_parts_net, 2) AS osa_parts_net,
       ROUND(100.0 * s.osa_parts_margin / NULLIF(s.osa_parts_net, 0), 1) AS osa_parts_margin_pct,
       ROUND(s.osa_net / NULLIF(s.osa_orders_invoiced, 0), 2) AS osa_net_per_invoiced_order,
       o.orders_with_value, ROUND(100.0 * o.orders_with_value / y.repairs, 1) AS orders_with_value_pct,
       ROUND(o.order_lines_net, 2) AS order_lines_net, ROUND(o.order_labour_net, 2) AS order_labour_net,
       ROUND(o.order_parts_net, 2) AS order_parts_net,
       ROUND(o.order_lines_net / NULLIF(o.orders_with_value, 0), 2) AS order_net_per_valued_order
FROM y LEFT JOIN s ON s.year = y.year LEFT JOIN o ON o.year = y.year
ORDER BY y.year

-- name: stock_assembly_orders
-- description: List of assembled items (PCs, NAS, bundles) in a period with their build cost and what happened next: assembly_id, assembled_on, item_code, description, qty built, unit_cost, components (lines), main components (first descriptions), qty_sold / sales_net / margin of that item code (sales_facts, any date after assembly), first_sale_date and days_to_sell, qty_on_hand (still in stock). Built items still in stock months later are stock tied up in finished goods.
-- params: start=last_year_start, end=today, limit=50
WITH s AS (
  SELECT o.assembly_id, SUM(f.qty) AS qty_sold, SUM(f.net) AS sales_net, SUM(f.margin) AS margin, MIN(f.doc_date) AS first_sale
  FROM assembly_orders o JOIN sales_facts f ON f.item_code = o.item_code AND f.doc_date >= o.assembled_on
  WHERE o.assembled_on BETWEEN :start AND :end GROUP BY o.assembly_id)
SELECT o.assembly_id, o.assembled_on, o.item_code, o.description, o.qty, o.unit_cost, o.component_lines,
       (SELECT substr(group_concat(description, ' | '),1,140) FROM (SELECT description FROM assembly_components c
          WHERE c.assembly_id = o.assembly_id AND c.series_year = o.series_year ORDER BY c.total_cost DESC LIMIT 4)) AS main_components,
       s.qty_sold, ROUND(s.sales_net,2) AS sales_net, ROUND(s.margin,2) AS margin, s.first_sale AS first_sale_date,
       CAST(julianday(s.first_sale) - julianday(o.assembled_on) AS INTEGER) AS days_to_sell,
       si.qty_on_hand
FROM assembly_orders o
LEFT JOIN s ON s.assembly_id = o.assembly_id
LEFT JOIN stock_items si ON si.item_code = o.item_code
WHERE o.assembled_on BETWEEN :start AND :end
ORDER BY o.assembled_on DESC
LIMIT :limit

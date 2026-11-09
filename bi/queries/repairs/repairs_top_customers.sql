-- name: repairs_top_customers
-- description: Customers who use the workshop the most (walk-in records excluded): repair orders, distinct devices, equipment mix, first/last repair, invoiced repair labour (ASSISTENCIA + travel/remote) and labour per repair, net invoiced from repair orders (OSA conversions, 2024+), total net purchases and product purchases in the same period. Customers with many repairs but little labour billed are candidates for a maintenance contract (avenca) or for checking unbilled work. order_by = repairs | labour_net | net_sales.
-- params: start=2021-01-01, end=2026-12-31, min_repairs=5, order_by=repairs, limit=50
WITH rp AS (
  SELECT customer_code, MAX(customer_name) AS customer_name, COUNT(*) AS repairs,
         COUNT(DISTINCT lower(trim(serial_number))) AS devices,
         SUM(equipment_type_code = 'not') AS notebooks, SUM(equipment_type_code IN ('des','all','min')) AS desktops,
         SUM(equipment_type_code IN ('imp','sca')) AS printers,
         MIN(opened_on) AS first_repair, MAX(opened_on) AS last_repair
  FROM repairs WHERE opened_on BETWEEN :start AND :end GROUP BY customer_code HAVING COUNT(*) >= :min_repairs),
sl AS (
  SELECT customer_code,
         SUM(CASE WHEN item_code IN ('ASSISTENCIA','Remoto','domicilio') OR family_name LIKE 'DESLOCA%' THEN net ELSE 0 END) AS labour_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' THEN net ELSE 0 END) AS osa_net,
         SUM(CASE WHEN line_kind = 'product' THEN net ELSE 0 END) AS product_net,
         SUM(net) AS net_sales, SUM(margin) AS gross_margin
  FROM sales_facts WHERE doc_date BETWEEN :start AND :end GROUP BY customer_code)
SELECT rp.customer_code, rp.customer_name, rp.repairs, rp.devices, rp.notebooks, rp.desktops, rp.printers,
       rp.first_repair, rp.last_repair,
       ROUND(COALESCE(sl.labour_net, 0), 2) AS labour_net,
       ROUND(COALESCE(sl.labour_net, 0) / rp.repairs, 2) AS labour_per_repair,
       ROUND(COALESCE(sl.osa_net, 0), 2) AS invoiced_from_repair_orders_net,
       ROUND(COALESCE(sl.product_net, 0), 2) AS product_net, ROUND(COALESCE(sl.net_sales, 0), 2) AS net_sales,
       ROUND(COALESCE(sl.gross_margin, 0), 2) AS gross_margin
FROM rp JOIN customers c ON c.customer_code = rp.customer_code AND c.is_walk_in = 0
LEFT JOIN sl ON sl.customer_code = rp.customer_code
ORDER BY CASE :order_by WHEN 'labour_net' THEN COALESCE(sl.labour_net, 0) WHEN 'net_sales' THEN COALESCE(sl.net_sales, 0) ELSE rp.repairs END DESC
LIMIT :limit

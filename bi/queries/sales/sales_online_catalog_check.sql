-- name: sales_online_catalog_check
-- description: Online-shop catalogue health per product group (view online_items = gGest e-commerce sync, Ecom_Artigos; started 2026): items published, active, active with stock 0, active with catalogue price 0, active not sold since sold_since, items not in the gGest catalogue, and in-stock catalogue products NOT published online. Use to clean the web shop (sold-out or unpriced items shown) and to find stock worth publishing.
-- params: sold_since=last_year_start
WITH s AS (SELECT DISTINCT item_code FROM sales_facts WHERE doc_date >= :sold_since),
o AS (SELECT COALESCE(group_name, '(fora do catalogo)') AS product_group, COUNT(*) AS published, SUM(is_active) AS active,
             SUM(is_active = 1 AND COALESCE(stock_qty, 0) <= 0) AS active_no_stock,
             SUM(is_active = 1 AND COALESCE(price_net, 0) = 0) AS active_no_price,
             SUM(is_active = 1 AND item_code NOT IN (SELECT item_code FROM s)) AS active_not_sold,
             SUM(description IS NULL) AS not_in_catalogue
      FROM online_items GROUP BY 1),
n AS (SELECT COALESCE(group_name, '(sem grupo)') AS product_group, COUNT(*) AS in_stock_not_online,
             ROUND(SUM(stock_qty * last_purchase_price), 0) AS stock_value_not_online
      FROM items WHERE kind = 'product' AND stock_qty > 0 AND item_code NOT IN (SELECT item_code FROM online_items) GROUP BY 1)
SELECT COALESCE(o.product_group, n.product_group) AS product_group, COALESCE(o.published, 0) AS published,
       COALESCE(o.active, 0) AS active, o.active_no_stock, o.active_no_price, o.active_not_sold, o.not_in_catalogue,
       COALESCE(n.in_stock_not_online, 0) AS in_stock_not_online, n.stock_value_not_online
FROM o LEFT JOIN n ON n.product_group = o.product_group
UNION ALL
SELECT n.product_group, 0, 0, NULL, NULL, NULL, NULL, n.in_stock_not_online, n.stock_value_not_online
FROM n WHERE n.product_group NOT IN (SELECT product_group FROM o)
ORDER BY published DESC
LIMIT 100

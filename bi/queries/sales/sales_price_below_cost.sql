-- name: sales_price_below_cost
-- description: Catalogue pricing check (view items): items whose current selling price net of VAT gives a markup below min_margin_pct over the last purchase net price (or is below it), limited to items in stock or sold since sold_since. Columns: item code, description, group/family/brand, price_net, last_purchase_price, last purchase date (ISO) and supplier, margin % at catalogue price, stock qty, units and net sold since sold_since, last sale date. Typical causes: supplier price went up and the shop price was not updated, unit mismatch (bought per box, sold per unit — huge negative margins) or wrong last price. total_items = all matching items (not only the rows shown). Excludes generic ZZ / diverso items and items with price 0 (priced at sale time).
-- params: min_margin_pct=15, sold_since=last_year_start, limit=50
WITH s AS (SELECT item_code, SUM(qty) AS qty, SUM(net) AS net, MAX(doc_date) AS last_sale
           FROM sales_facts WHERE doc_date >= :sold_since AND item_code IS NOT NULL GROUP BY item_code)
SELECT i.item_code, i.description, i.group_name, i.family_name, i.brand_name,
       ROUND(i.price_net, 2) AS price_net, ROUND(i.last_purchase_price, 2) AS last_purchase_price,
       CASE WHEN i.last_purchase_date > '19000000' THEN date(substr(i.last_purchase_date,1,4)||'-'||substr(i.last_purchase_date,5,2)||'-'||substr(i.last_purchase_date,7,2)) END AS last_purchase_date, i.last_supplier,
       ROUND(100.0 * (i.price_net - i.last_purchase_price) / i.price_net, 1) AS margin_pct_at_list_price,
       i.stock_qty, ROUND(s.qty, 1) AS qty_sold, ROUND(s.net, 2) AS net_sold, s.last_sale,
       COUNT(*) OVER () AS total_items
FROM items i LEFT JOIN s ON s.item_code = i.item_code
WHERE i.kind = 'product' AND i.price_net > 0 AND i.last_purchase_price > 0
  AND upper(i.item_code) <> 'ZZ' AND lower(i.item_code) NOT LIKE '%diverso%'
  AND 100.0 * (i.price_net - i.last_purchase_price) / i.price_net < :min_margin_pct
  AND (i.stock_qty > 0 OR s.qty > 0)
ORDER BY (i.price_net - i.last_purchase_price) * MAX(COALESCE(i.stock_qty, 0), COALESCE(s.qty, 0), 1) ASC
LIMIT :limit

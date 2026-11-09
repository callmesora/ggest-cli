-- name: stock_cleanup_candidates
-- description: Stock to clear: goods in stock with no sale for at least `months` months, valued at cost, with a suggested action. Columns: item, group, qty, unit_cost, stock_value, price_net, last_sale (blank = never sold since 2017), last_purchase, last_supplier, units_sold_24m, months_idle, suggested_action: return_to_supplier (bought in the last 12 months but not selling), use_in_repairs (spare parts group), write_off_or_sell_at_cost (never sold and bought more than 24 months ago, or idle more than 36 months), promote_or_bundle (the rest: promotions, PC bundles). Non-stock items (software/licences, hosting, services, freight: stock_items.is_stock_item = 0) are excluded. Items bought in the last `grace_months` months are not listed (not yet had time to sell). Complements finance_dead_stock_items (which also counts purchases as activity). `group` filters by part of the group name.
-- params: as_of=today, months=12, grace_months=3, min_value=10, group=, limit=50
WITH ls AS (
  SELECT item_code, MAX(CASE WHEN movement_kind = 'sale' THEN doc_date END) AS last_sale,
         -SUM(CASE WHEN doc_date > date(:as_of,'-24 months') THEN qty ELSE 0 END) AS units_sold_24m
  FROM stock_movements WHERE movement_kind IN ('sale','sale_return') GROUP BY item_code),
st AS (
  SELECT s.*, COALESCE(ls.last_sale, s.last_sale_date) AS last_sale, CAST(COALESCE(ls.units_sold_24m,0) AS INTEGER) AS units_sold_24m
  FROM stock_items s LEFT JOIN ls ON ls.item_code = s.item_code
  WHERE s.is_stock_item = 1 AND s.qty_on_hand > 0)
SELECT item_code, description, group_name, qty_on_hand AS qty, ROUND(unit_cost,2) AS unit_cost, stock_value,
       ROUND(price_net,2) AS price_net, last_sale, last_purchase_date AS last_purchase, last_supplier_name AS last_supplier,
       units_sold_24m,
       CAST((julianday(:as_of) - julianday(COALESCE(last_sale, last_purchase_date, '2017-01-01'))) / 30.4 AS INTEGER) AS months_idle,
       CASE WHEN last_purchase_date > date(:as_of,'-12 months') THEN 'return_to_supplier'
            WHEN upper(group_name) LIKE 'SPA%' OR lower(group_name) LIKE '%pe_as%' THEN 'use_in_repairs'
            WHEN (last_sale IS NULL AND COALESCE(last_purchase_date,'2017-01-01') < date(:as_of,'-24 months'))
                 OR COALESCE(last_sale, last_purchase_date, '2017-01-01') < date(:as_of,'-36 months') THEN 'write_off_or_sell_at_cost'
            ELSE 'promote_or_bundle' END AS suggested_action
FROM st
WHERE COALESCE(last_sale,'2000-01-01') < date(:as_of, '-' || :months || ' months')
  AND COALESCE(last_purchase_date,'2000-01-01') < date(:as_of, '-' || :grace_months || ' months')
  AND stock_value >= :min_value
  AND (:group = '' OR group_name LIKE '%' || :group || '%')
ORDER BY stock_value DESC
LIMIT :limit

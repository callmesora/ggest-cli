-- name: stock_cleanup_summary
-- description: Size of the stock clean-up per catalogue group: value of goods with no sale for at least `months` months (same rules as stock_cleanup_candidates, items bought in the last `grace_months` months excluded), with the group's total stock value (items_in_stock, stock_value) and the idle share of it (idle_pct_of_group; on the TOTAL row = idle share of all stock), and value per suggested action (return_to_supplier, use_in_repairs, write_off_or_sell_at_cost, promote_or_bundle). Last row TOTAL (all stocked goods). Stock at cost (stock_items); non-stock items (software, hosting, services) excluded.
-- params: as_of=today, months=12, grace_months=3
WITH ls AS (SELECT item_code, MAX(doc_date) AS last_sale FROM stock_movements WHERE movement_kind = 'sale' GROUP BY item_code),
st AS (
  SELECT s.item_code, s.group_name, s.stock_value, s.last_purchase_date, COALESCE(ls.last_sale, s.last_sale_date) AS last_sale
  FROM stock_items s LEFT JOIN ls ON ls.item_code = s.item_code
  WHERE s.is_stock_item = 1 AND s.qty_on_hand > 0),
c AS (
  SELECT *, CASE WHEN COALESCE(last_sale,'2000-01-01') < date(:as_of, '-' || :months || ' months')
                   AND COALESCE(last_purchase_date,'2000-01-01') < date(:as_of, '-' || :grace_months || ' months') THEN 1 ELSE 0 END AS idle,
         CASE WHEN last_purchase_date > date(:as_of,'-12 months') THEN 'return_to_supplier'
              WHEN upper(group_name) LIKE 'SPA%' OR lower(group_name) LIKE '%pe_as%' THEN 'use_in_repairs'
              WHEN (last_sale IS NULL AND COALESCE(last_purchase_date,'2017-01-01') < date(:as_of,'-24 months'))
                   OR COALESCE(last_sale, last_purchase_date, '2017-01-01') < date(:as_of,'-36 months') THEN 'write_off_or_sell_at_cost'
              ELSE 'promote_or_bundle' END AS action
  FROM st),
g AS (
  SELECT group_name, COUNT(*) AS items_in_stock, ROUND(SUM(stock_value),0) AS stock_value, SUM(idle) AS idle_items, ROUND(SUM(idle*stock_value),0) AS idle_value,
         ROUND(100.0*SUM(idle*stock_value)/SUM(stock_value),1) AS idle_pct_of_group,
         ROUND(SUM(CASE WHEN idle = 1 AND action = 'return_to_supplier' THEN stock_value ELSE 0 END),0) AS return_to_supplier,
         ROUND(SUM(CASE WHEN idle = 1 AND action = 'use_in_repairs' THEN stock_value ELSE 0 END),0) AS use_in_repairs,
         ROUND(SUM(CASE WHEN idle = 1 AND action = 'write_off_or_sell_at_cost' THEN stock_value ELSE 0 END),0) AS write_off_or_sell_at_cost,
         ROUND(SUM(CASE WHEN idle = 1 AND action = 'promote_or_bundle' THEN stock_value ELSE 0 END),0) AS promote_or_bundle
  FROM c GROUP BY group_name)
SELECT * FROM (SELECT * FROM g WHERE idle_items > 0 ORDER BY idle_value DESC)
UNION ALL
SELECT 'TOTAL', COUNT(*), ROUND(SUM(stock_value),0), SUM(idle), ROUND(SUM(idle*stock_value),0), ROUND(100.0*SUM(idle*stock_value)/SUM(stock_value),1),
       ROUND(SUM(CASE WHEN idle = 1 AND action = 'return_to_supplier' THEN stock_value ELSE 0 END),0),
       ROUND(SUM(CASE WHEN idle = 1 AND action = 'use_in_repairs' THEN stock_value ELSE 0 END),0),
       ROUND(SUM(CASE WHEN idle = 1 AND action = 'write_off_or_sell_at_cost' THEN stock_value ELSE 0 END),0),
       ROUND(SUM(CASE WHEN idle = 1 AND action = 'promote_or_bundle' THEN stock_value ELSE 0 END),0)
FROM c

-- name: stock_supplier_best_prices
-- description: Same item bought from more than one supplier in the last `months` months: cheapest supplier and cost vs the most-used supplier and its average cost, with the potential saving had all units been bought at the cheapest cost. Columns: item_code, description, suppliers (count), cheapest_supplier, cheapest_cost, main_supplier (most units), main_avg_cost, qty_bought, potential_saving. Net unit costs after discounts, VAT excluded; inbound freight not included (compare landed cost before switching); freight items (group PORTES) excluded. Prices move over time (e.g. memory/SSD in 2025-26): check the dates with stock_item_purchase_history.
-- params: as_of=today, months=12, limit=50
WITH l AS (
  SELECT item_code, supplier_code, MAX(supplier_name) AS supplier_name, SUM(qty) AS qty, SUM(net) / SUM(qty) AS avg_cost, MIN(unit_cost_net) AS min_cost
  FROM stock_purchase_lines
  WHERE is_return = 0 AND is_cancelled = 0 AND line_kind = 'product' AND qty > 0 AND unit_cost_net > 0
    AND item_code IS NOT NULL AND item_code <> 'ZZ' AND doc_date > date(:as_of, '-' || :months || ' months') AND doc_date <= :as_of
  GROUP BY item_code, supplier_code),
r AS (
  SELECT l.*, ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY avg_cost) AS r_cheap,
         ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY qty DESC, avg_cost DESC) AS r_main,
         COUNT(*) OVER (PARTITION BY item_code) AS suppliers, SUM(qty) OVER (PARTITION BY item_code) AS qty_total,
         SUM(qty*avg_cost) OVER (PARTITION BY item_code) AS spend_total
  FROM l)
SELECT c.item_code, s.description, c.suppliers, c.supplier_name AS cheapest_supplier, ROUND(c.avg_cost,2) AS cheapest_cost,
       m.supplier_name AS main_supplier, ROUND(m.avg_cost,2) AS main_avg_cost, c.qty_total AS qty_bought,
       ROUND(c.spend_total - c.qty_total * c.avg_cost, 2) AS potential_saving
FROM r c JOIN r m ON m.item_code = c.item_code AND m.r_main = 1
LEFT JOIN stock_items s ON s.item_code = c.item_code
WHERE c.r_cheap = 1 AND c.suppliers > 1 AND COALESCE(s.group_name,'') NOT LIKE 'PORTES%' AND lower(COALESCE(s.description,'')) NOT LIKE 'portes%'
ORDER BY potential_saving DESC
LIMIT :limit

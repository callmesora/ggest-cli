-- name: stock_reorder_suggestions
-- description: What to buy now: stocked goods that moved in the last `days` days (sales + components used in PC assembly, net of returns, from stock_movements) whose current stock covers fewer than `target_days` days. Non-stock items (software/licences, hosting, services, freight) are excluded (stock_items.is_stock_item). group_by=item (default): one row per item with supplier (last real purchase), units_out, customers, qty_on_hand, days_of_cover, suggested_qty (= demand rate x target_days - stock, rounded up), last_cost (last purchase invoice, net), order_value (= suggested_qty x last_cost), cheapest supplier/cost of the last 12 months, price_net, margin_pct, last_sale. group_by=supplier: one row per supplier (the purchase order to place) with items, units, suggested_qty and order_value totals and the item list in `description`. Items with fewer than `min_out` units out are ignored (one-off sales are bought on demand). `group` filters by part of the catalogue group name. Assumes steady demand; supplier orders are not recorded in gGest, so check open orders before buying.
-- params: as_of=today, days=90, target_days=45, min_out=3, group=, group_by=item, limit=50
WITH dem AS (
  SELECT item_code, -SUM(qty) AS units_out, COUNT(DISTINCT CASE WHEN movement_kind = 'sale' THEN entity_code END) AS customers,
         MAX(CASE WHEN movement_kind = 'sale' THEN doc_date END) AS last_sale
  FROM stock_movements
  WHERE movement_kind IN ('sale','sale_return','assembly_out')
    AND doc_date > date(:as_of, '-' || :days || ' days') AND doc_date <= :as_of
  GROUP BY item_code),
best AS (
  SELECT item_code, supplier_name, unit_cost_net,
         ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY unit_cost_net) AS rn
  FROM stock_purchase_lines
  WHERE is_return = 0 AND is_cancelled = 0 AND qty > 0 AND unit_cost_net > 0 AND doc_date > date(:as_of, '-12 months')),
r AS (
  SELECT COALESCE(s.last_supplier_name, '(sem fornecedor)') AS supplier, s.item_code, s.description, s.group_name,
         d.units_out, d.customers, d.last_sale, s.qty_on_hand,
         CASE WHEN d.units_out > 0 THEN ROUND(MAX(s.qty_on_hand,0) / (d.units_out * 1.0 / :days), 0) END AS days_of_cover,
         MAX(0, CAST(d.units_out * 1.0 / :days * :target_days + 0.999 AS INTEGER) - CAST(MAX(s.qty_on_hand,0) AS INTEGER)) AS suggested_qty,
         s.last_purchase_cost AS last_cost, b.supplier_name AS cheapest_supplier_12m, b.unit_cost_net AS cheapest_cost_12m,
         s.price_net,
         d.units_out * 1.0 / :days * :target_days - s.qty_on_hand AS shortfall
  FROM dem d
  JOIN stock_items s ON s.item_code = d.item_code
  LEFT JOIN best b ON b.item_code = d.item_code AND b.rn = 1
  WHERE s.is_stock_item = 1 AND d.units_out >= :min_out
    AND (:group = '' OR s.group_name LIKE '%' || :group || '%')
    AND MAX(s.qty_on_hand,0) < d.units_out * 1.0 / :days * :target_days)
SELECT supplier,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(item_code) END AS item_code,
       CASE WHEN :group_by = 'supplier' THEN substr(group_concat(item_code || ' ' || substr(description,1,30), ' | '),1,200) ELSE MAX(description) END AS description,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(group_name) END AS group_name,
       COUNT(*) AS items, SUM(units_out) AS units_out, SUM(customers) AS customers, SUM(qty_on_hand) AS qty_on_hand,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(days_of_cover) END AS days_of_cover,
       SUM(suggested_qty) AS suggested_qty,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(last_cost),2) END AS last_cost,
       ROUND(SUM(suggested_qty * COALESCE(last_cost,0)),2) AS order_value,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(cheapest_supplier_12m) END AS cheapest_supplier_12m,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(cheapest_cost_12m),2) END AS cheapest_cost_12m,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(price_net),2) END AS price_net,
       CASE WHEN :group_by = 'supplier' OR MAX(price_net) <= 0 THEN NULL ELSE ROUND(100.0 * (MAX(price_net) - MAX(last_cost)) / MAX(price_net), 1) END AS margin_pct,
       MAX(last_sale) AS last_sale
FROM r
GROUP BY CASE WHEN :group_by = 'supplier' THEN supplier ELSE item_code END
ORDER BY CASE WHEN :group_by = 'supplier' THEN -SUM(suggested_qty * COALESCE(last_cost,0)) ELSE 0 END,
         CASE WHEN MIN(qty_on_hand) <= 0 THEN 0 ELSE 1 END, MAX(shortfall) DESC
LIMIT :limit

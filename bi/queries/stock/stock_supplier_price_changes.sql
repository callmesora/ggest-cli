-- name: stock_supplier_price_changes
-- description: Purchase price evolution: goods bought both in the last 12 months and in the 12 months before, comparing the latest net unit cost (purchase invoices, after line discounts, VAT excluded) with the average net unit cost of the previous 12 months. `min_change_pct` is ABSOLUTE (5 = changes of at least +5 % or -5 %); `direction` = up (increases only), down (decreases only) or both (increases listed first). Jumps above +`max_change_pct` % (or the equivalent drop) are usually a change of purchase unit (box vs metre) and are excluded, as are freight items. group_by=item (default): one row per item with supplier (latest), direction, last_cost, last_date, prev_avg_cost, change_pct, qty_bought_12m, extra_cost_12m (= price change x units bought in the last 12 months; negative = saving), price_net, margin_pct at the latest cost. group_by=supplier: one row per supplier with items, items_up, items_down, change_pct (weighted by units bought), extra_cost_12m total and spend_12m at the latest costs. Use to renegotiate or update selling prices.
-- params: as_of=today, min_change_pct=5, max_change_pct=150, direction=both, group_by=item, limit=50
WITH l AS (
  SELECT item_code, supplier_name, doc_date, unit_cost_net, qty
  FROM stock_purchase_lines
  WHERE is_return = 0 AND is_cancelled = 0 AND line_kind = 'product' AND qty > 0 AND unit_cost_net > 0
    AND item_code IS NOT NULL AND item_code <> 'ZZ' AND doc_date > date(:as_of,'-24 months') AND doc_date <= :as_of),
last AS (
  SELECT item_code, supplier_name, doc_date, unit_cost_net,
         ROW_NUMBER() OVER (PARTITION BY item_code ORDER BY doc_date DESC, unit_cost_net DESC) AS rn
  FROM l WHERE doc_date > date(:as_of,'-12 months')),
prev AS (SELECT item_code, SUM(unit_cost_net*qty)/SUM(qty) AS prev_avg FROM l WHERE doc_date <= date(:as_of,'-12 months') GROUP BY item_code),
q12 AS (SELECT item_code, SUM(qty) AS qty12 FROM l WHERE doc_date > date(:as_of,'-12 months') GROUP BY item_code),
r AS (
  SELECT s.item_code, s.description, s.group_name, last.supplier_name AS supplier,
         CASE WHEN last.unit_cost_net > prev.prev_avg THEN 'up' ELSE 'down' END AS direction,
         last.unit_cost_net AS last_cost, last.doc_date AS last_date, prev.prev_avg, q12.qty12, s.price_net
  FROM last JOIN prev ON prev.item_code = last.item_code
  JOIN q12 ON q12.item_code = last.item_code
  JOIN stock_items s ON s.item_code = last.item_code
  WHERE last.rn = 1 AND ABS(100.0*(last.unit_cost_net - prev.prev_avg)/prev.prev_avg) >= ABS(:min_change_pct)
    AND last.unit_cost_net / prev.prev_avg BETWEEN 1.0 / (1 + :max_change_pct / 100.0) AND 1 + :max_change_pct / 100.0
    AND s.group_name NOT LIKE 'PORTES%'
    AND (:direction = 'both' OR :direction = CASE WHEN last.unit_cost_net > prev.prev_avg THEN 'up' ELSE 'down' END))
SELECT supplier,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(item_code) END AS item_code,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(description) END AS description,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(group_name) END AS group_name,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(direction) END AS direction,
       COUNT(*) AS items, SUM(direction = 'up') AS items_up, SUM(direction = 'down') AS items_down,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(last_cost),2) END AS last_cost,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE MAX(last_date) END AS last_date,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(prev_avg),2) END AS prev_avg_cost,
       ROUND(100.0 * SUM((last_cost - prev_avg) * qty12) / SUM(prev_avg * qty12), 1) AS change_pct,
       SUM(qty12) AS qty_bought_12m,
       ROUND(SUM((last_cost - prev_avg) * qty12), 2) AS extra_cost_12m,
       ROUND(SUM(last_cost * qty12), 2) AS spend_12m,
       CASE WHEN :group_by = 'supplier' THEN NULL ELSE ROUND(MAX(price_net),2) END AS price_net,
       CASE WHEN :group_by = 'supplier' OR MAX(price_net) <= 0 THEN NULL ELSE ROUND(100.0*(MAX(price_net) - MAX(last_cost))/MAX(price_net),1) END AS margin_pct
FROM r
GROUP BY CASE WHEN :group_by = 'supplier' THEN supplier ELSE item_code END
ORDER BY CASE WHEN :group_by = 'supplier' THEN 0 WHEN MAX(direction) = 'up' THEN 0 ELSE 1 END,
         CASE WHEN :group_by = 'supplier' THEN -SUM((last_cost - prev_avg) * qty12) ELSE -ABS(SUM((last_cost - prev_avg) * qty12)) END
LIMIT :limit

-- name: stock_supplier_rmas
-- description: Warranty returns to suppliers (RMA module assTec_RMA) per supplier: RMAs opened, distinct items, average age of the item when the RMA was opened (days since our purchase), average days from shipping to the supplier's resolution (often not filled), shipping costs paid, and how many originated in a repair order. Recorded only 2020-05 to 2024-04 in this database (the RMA module stopped being used); `start` empty = all history; supplier credit notes for returned goods are in stock_supplier_scorecard (credited).
-- params: start=, end=today
SELECT supplier_code, supplier_name, COUNT(*) AS rmas, COUNT(DISTINCT item_code) AS items,
       MIN(opened_on) AS first_rma, MAX(opened_on) AS last_rma,
       ROUND(AVG(julianday(opened_on) - julianday(purchased_on)),0) AS avg_item_age_days,
       ROUND(AVG(julianday(supplier_resolved_on) - julianday(sent_on)),0) AS avg_days_supplier_resolution,
       ROUND(SUM(shipping_cost),2) AS shipping_costs,
       SUM(origin_repair_id IS NOT NULL) AS from_repairs
FROM supplier_rmas
WHERE (:start = '' OR opened_on >= :start) AND opened_on <= :end
GROUP BY supplier_code, supplier_name
ORDER BY rmas DESC

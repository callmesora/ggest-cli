-- name: repairs_supplier_rmas
-- description: Supplier RMAs registered in the gGest RMA module (assTec_RMA via view repair_rmas; module used 2020-2024 only, ~6% of repairs mention RMA in the notes instead). One row per RMA: number, status (open/closed), opened, shipped and received-back dates, days_out (received_back - shipped; for open RMAs without a return date, days until as_of = stale/unresolved; NULL for closed RMAs without a return date), supplier, item, serial, carrier and shipping cost, linked repair order and customer code, sale and purchase dates. status = all | open | closed. grain=list (rows) or grain=supplier (count, open, avg days out, shipping cost per supplier).
-- params: status=all, grain=list, as_of=today, limit=100
WITH m AS (
  SELECT r.*, CAST(julianday(CASE WHEN r.received_back_on IS NOT NULL THEN r.received_back_on WHEN r.status = 'open' THEN :as_of END)
                - julianday(COALESCE(r.shipped_on, r.opened_on)) AS INTEGER) AS days_out
  FROM repair_rmas r WHERE :status = 'all' OR r.status = :status)
SELECT * FROM (
  SELECT 'list' AS grain, rma_number, status, opened_on, shipped_on, received_back_on, days_out, supplier_code, supplier_name,
         item_code, item_description, serial_number, carrier, shipping_cost, repair_id, customer_code, sold_on, purchased_on,
         NULL AS rmas, NULL AS open_rmas
  FROM m WHERE :grain = 'list'
  UNION ALL
  SELECT 'supplier', NULL, NULL, MIN(opened_on), NULL, MAX(opened_on), ROUND(AVG(days_out), 1), supplier_code, supplier_name,
         NULL, NULL, NULL, NULL, ROUND(SUM(shipping_cost), 2), NULL, NULL, NULL, NULL, COUNT(*), SUM(status = 'open')
  FROM m WHERE :grain = 'supplier' GROUP BY supplier_code, supplier_name)
ORDER BY CASE WHEN grain = 'supplier' THEN -rmas END, opened_on DESC
LIMIT :limit

-- name: repairs_warranty_check
-- description: Is this serial number under warranty? For a serial (case-insensitive exact match; exact=0 for substring, min 5 chars): item, purchase from supplier (date, supplier, document), sale to customer (last non-cancelled, not credited sale: date, customer, document), warranty term in months from the serial registry (Artigos_series: type 1 = years, 2 = months; 24 assumed when missing), customer warranty end = sale + term, in_warranty at as_of, days left, approximate supplier warranty end (purchase + term) and whether it still holds (decides if a supplier RMA is possible), number of repair orders and supplier RMAs for this serial. sold_here = 0 means the shop has no sale of this serial (bought elsewhere, sold before serial tracking (2017) or typed differently). Portuguese consumer law: 3 years for goods bought from 2022 (2 years before) - the gGest term may be shorter; check with the owner.
-- params: serial=, exact=1, as_of=today
WITH
cand AS (
  SELECT g.item_code, g.item_description, g.serial_number, g.serial_key, g.warranty_months, g.purchased_on, g.supplier_name,
         g.purchase_doc_id, g.sold_on, g.customer_code, g.customer_name, g.sale_doc_id
  FROM serial_registry g
  WHERE length(lower(trim(:serial))) >= 3 AND (g.serial_key = lower(trim(:serial)) OR (:exact = 0 AND length(lower(trim(:serial))) >= 5 AND g.serial_key LIKE '%' || lower(trim(:serial)) || '%'))
  UNION ALL   -- serials moved on documents but missing from the registry
  SELECT h.item_code, max(h.item_description), max(h.serial_number), h.serial_key, NULL,
         min(CASE WHEN h.movement = 'purchase' AND h.is_cancelled = 0 THEN h.movement_date END),
         max(CASE WHEN h.movement = 'purchase' THEN h.entity_name END),
         max(CASE WHEN h.movement = 'purchase' THEN h.doc_id END),
         max(CASE WHEN h.movement = 'sale' AND h.is_cancelled = 0 AND h.is_credited = 0 THEN h.movement_date END),
         max(CASE WHEN h.movement = 'sale' AND h.is_cancelled = 0 THEN h.entity_code END),
         max(CASE WHEN h.movement = 'sale' AND h.is_cancelled = 0 THEN h.entity_name END),
         max(CASE WHEN h.movement = 'sale' AND h.is_cancelled = 0 THEN h.doc_id END)
  FROM serial_history h
  WHERE length(lower(trim(:serial))) >= 3 AND (h.serial_key = lower(trim(:serial)) OR (:exact = 0 AND length(lower(trim(:serial))) >= 5 AND h.serial_key LIKE '%' || lower(trim(:serial)) || '%'))
    AND h.movement IN ('purchase','sale')
    AND NOT EXISTS (SELECT 1 FROM Artigos_series a WHERE a.Codigo = h.item_code AND lower(trim(a.Serie)) = h.serial_key)
  GROUP BY h.item_code, h.serial_key)
SELECT c.serial_number, c.item_code, c.item_description,
       c.purchased_on, c.supplier_name, c.purchase_doc_id,
       CASE WHEN c.sold_on IS NOT NULL THEN 1 ELSE 0 END AS sold_here, c.sold_on, c.customer_code, c.customer_name, c.sale_doc_id,
       COALESCE(c.warranty_months, 24) AS warranty_months, CASE WHEN c.warranty_months IS NULL THEN 'assumido' ELSE 'gGest' END AS term_source,
       date(c.sold_on, '+' || COALESCE(c.warranty_months, 24) || ' months') AS warranty_end,
       CASE WHEN c.sold_on IS NULL THEN NULL WHEN :as_of <= date(c.sold_on, '+' || COALESCE(c.warranty_months, 24) || ' months') THEN 1 ELSE 0 END AS in_warranty,
       CAST(julianday(date(c.sold_on, '+' || COALESCE(c.warranty_months, 24) || ' months')) - julianday(:as_of) AS INTEGER) AS days_left,
       date(c.purchased_on, '+' || COALESCE(c.warranty_months, 24) || ' months') AS supplier_warranty_end_approx,
       CASE WHEN c.purchased_on IS NULL THEN NULL WHEN :as_of <= date(c.purchased_on, '+' || COALESCE(c.warranty_months, 24) || ' months') THEN 1 ELSE 0 END AS supplier_warranty_ok,
       (SELECT COUNT(*) FROM repairs r WHERE lower(trim(r.serial_number)) = c.serial_key) AS repair_orders,
       (SELECT COUNT(*) FROM repair_rmas m WHERE lower(m.serial_number) = c.serial_key) AS supplier_rmas
FROM cand c
ORDER BY c.sold_on DESC
LIMIT 50

-- name: customers_devices
-- description: Installed base of one customer (what equipment they have): source = repair (equipment brought to the workshop: type, brand, model, distinct serials, repairs, first/last repair) and source = purchase (products bought with unit price net >= min_unit_price: group, family, item, quantity, last purchase, net). Useful to prepare a visit, spot old equipment to replace, or offer warranty extension / maintenance. customer = customer code or NIF; merge_nif = 1 includes the other records with the same NIF.
-- params: customer=, merge_nif=1, min_unit_price=100, limit=60
WITH t AS MATERIALIZED (
  SELECT d.customer_code FROM customer_dim d
  WHERE d.customer_code = :customer OR d.nif_clean = upper(replace(:customer, ' ', ''))
     OR (:merge_nif = 1 AND d.entity_key = (SELECT entity_key FROM customer_dim WHERE customer_code = :customer))),
rp AS (
  SELECT 'repair' AS source, COALESCE(equipment_type, '?') AS category, COALESCE(brand_name, '') AS brand,
         lower(trim(COALESCE(model, ''))) AS model_or_item,
         COUNT(DISTINCT NULLIF(lower(trim(serial_number)), '')) AS distinct_serials, COUNT(*) AS events,
         MIN(opened_on) AS first_date, MAX(opened_on) AS last_date, NULL AS net
  FROM repairs WHERE customer_code IN (SELECT customer_code FROM t)
  GROUP BY 2, 3, 4),
pu AS (
  SELECT 'purchase' AS source, COALESCE(group_name, '?') || ' / ' || COALESCE(family_name, '?') AS category,
         COALESCE(brand_name, '') AS brand, item_description AS model_or_item, NULL AS distinct_serials,
         CAST(SUM(qty) AS INTEGER) AS events, MIN(doc_date) AS first_date, MAX(doc_date) AS last_date, ROUND(SUM(net), 2) AS net
  FROM sales_facts
  WHERE customer_code IN (SELECT customer_code FROM t) AND line_kind = 'product' AND unit_price_net >= :min_unit_price
  GROUP BY 2, 3, 4 HAVING SUM(qty) > 0)
SELECT *, CAST(julianday((SELECT MAX(doc_date) FROM sales_docs)) - julianday(last_date) AS INTEGER) / 365 AS years_since_last
FROM (SELECT * FROM rp UNION ALL SELECT * FROM pu)
ORDER BY last_date DESC LIMIT :limit

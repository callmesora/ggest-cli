-- name: repairs_customer_devices
-- description: Installed base of ONE customer (customer = exact customer code, or part of the name, case-insensitive): every serial-numbered item sold to them (serial_registry + sales serials: item, serial, sale date and document, warranty months, warranty end and in_warranty at as_of, repair orders on that serial) plus devices they brought for repair that were not sold by the shop (serial, equipment, brand, repairs, first/last repair). source = sold_here | repaired_only. Use before a visit or when the customer calls ("what do they have, what is still under warranty"). Only items with serial tracking (mostly computers, printers, monitors, UPS, phones since 2017).
-- params: customer=, as_of=today, limit=200
WITH c AS (SELECT customer_code FROM customers
           WHERE customer_code = :customer OR (length(:customer) >= 3 AND lower(name) LIKE '%' || lower(:customer) || '%')),
sold AS (
  SELECT h.serial_key, max(h.serial_number) AS serial_number, h.item_code, max(h.item_description) AS item_description,
         max(h.movement_date) AS sold_on, max(h.doc_id) AS sale_doc_id, max(h.entity_code) AS customer_code, max(h.entity_name) AS customer_name
  FROM serial_history h
  WHERE h.movement = 'sale' AND h.is_cancelled = 0 AND h.is_credited = 0 AND h.entity_code IN (SELECT customer_code FROM c)
  GROUP BY h.serial_key, h.item_code),
wm AS (SELECT lower(trim(s.Serie)) AS k, s.Codigo,
              CASE WHEN s.Tipo_Garantia = '1' AND CAST(s.Prazo_Garantia AS INTEGER) BETWEEN 1 AND 10 THEN CAST(s.Prazo_Garantia AS INTEGER) * 12
                   WHEN s.Tipo_Garantia = '2' AND CAST(s.Prazo_Garantia AS INTEGER) BETWEEN 1 AND 120 THEN CAST(s.Prazo_Garantia AS INTEGER) END AS months
       FROM Artigos_series s WHERE lower(trim(s.Serie)) IN (SELECT serial_key FROM sold)),
rep AS (
  SELECT lower(trim(serial_number)) AS k, max(serial_number) AS serial_number, max(customer_code) AS customer_code, max(customer_name) AS customer_name,
         max(COALESCE(equipment_type, equipment_type_code)) AS equipment, max(brand_name) AS brand, COUNT(*) AS repairs,
         MIN(opened_on) AS first_repair, MAX(opened_on) AS last_repair
  FROM repairs WHERE customer_code IN (SELECT customer_code FROM c) AND length(trim(serial_number)) >= 4
  GROUP BY 1)
SELECT * FROM (
  SELECT 'sold_here' AS source, s.customer_code, s.customer_name, s.serial_number, s.item_code, s.item_description AS item_or_equipment,
         s.sold_on, s.sale_doc_id, COALESCE(w.months, 24) AS warranty_months,
         date(s.sold_on, '+' || COALESCE(w.months, 24) || ' months') AS warranty_end,
         CASE WHEN :as_of <= date(s.sold_on, '+' || COALESCE(w.months, 24) || ' months') THEN 1 ELSE 0 END AS in_warranty,
         COALESCE(r.repairs, 0) AS repairs, r.last_repair
  FROM sold s LEFT JOIN wm w ON w.k = s.serial_key AND w.Codigo = s.item_code LEFT JOIN rep r ON r.k = s.serial_key
  UNION ALL
  SELECT 'repaired_only', r.customer_code, r.customer_name, r.serial_number, NULL, trim(COALESCE(r.equipment, '') || ' ' || COALESCE(r.brand, '')),
         NULL, NULL, NULL, NULL, NULL, r.repairs, r.last_repair
  FROM rep r WHERE r.k NOT IN (SELECT serial_key FROM sold))
ORDER BY source DESC, COALESCE(sold_on, last_repair) DESC
LIMIT :limit

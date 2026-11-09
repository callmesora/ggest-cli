-- name: stock_serials_sold
-- description: Serial numbers sold in a period (sales invoices FT/FR/FS/FTGOL, cancelled documents excluded), with the customer, item, sale document and date, warranty term and end date (sale date + warranty years), and where we bought it (supplier and purchase date of the serial's first purchase document, for the supplier warranty). Filters (empty = all): `customer` = customer code or part of the name, `item` = item code or words of the description, `serial` = part of the serial number. Use to find "which serial did we sell to X in 2025" or all serials of a model sold in a period. Columns: doc_date, doc_id, customer_code, customer_name, item_code, item_description, serial_number, warranty_years, warranty_until, purchased_on, supplier.
-- params: start=last_year_start, end=today, customer=, item=, serial=, limit=100
WITH s AS (
  SELECT m.* FROM serial_movements m
  WHERE m.doc_type IN ('FT','FR','FS','FTGOL') AND m.is_cancelled = 0 AND m.doc_date BETWEEN :start AND :end
    AND (:serial = '' OR lower(m.serial_number) LIKE '%' || lower(trim(:serial)) || '%')
    AND (:item = '' OR lower(m.item_code) = lower(trim(:item))
         OR lower(m.item_description) LIKE '%' || replace(lower(trim(:item)), ' ', '%') || '%')),
p AS (
  SELECT m.serial_number, m.item_code, m.doc_date, m.entity_code,
         ROW_NUMBER() OVER (PARTITION BY m.serial_number, m.item_code ORDER BY m.doc_date) AS rn
  FROM serial_movements m JOIN (SELECT DISTINCT serial_number, item_code FROM s) k
    ON k.serial_number = m.serial_number AND k.item_code = m.item_code
  WHERE m.doc_type IN ('VFT','VFR','VFS','FTINC','FTEXC'))
SELECT s.doc_date, s.doc_id, s.entity_code AS customer_code, c.name AS customer_name, s.item_code, s.item_description,
       s.serial_number, s.warranty_years,
       CASE WHEN CAST(s.warranty_years AS INTEGER) > 0 THEN date(s.doc_date, '+' || CAST(s.warranty_years AS INTEGER) || ' years') END AS warranty_until,
       p.doc_date AS purchased_on, sp.name AS supplier
FROM s
LEFT JOIN customers c ON c.customer_code = s.entity_code
LEFT JOIN p ON p.serial_number = s.serial_number AND p.item_code = s.item_code AND p.rn = 1
LEFT JOIN suppliers sp ON sp.supplier_code = p.entity_code
WHERE (:customer = '' OR s.entity_code = CAST(:customer AS TEXT) OR lower(c.name) LIKE '%' || lower(trim(:customer)) || '%')
ORDER BY s.doc_date DESC, s.doc_id
LIMIT :limit

-- name: stock_serial_lookup
-- description: History of a serial number (or part of it, min. 3 characters): every document that moved it — purchase (supplier, date: start of the supplier warranty), sale/repair/quote (customer), assembly, stock exits — oldest first, with the item and its warranty term in years and current status (in_stock / out). Use for warranty claims ("when and from whom did we buy it, when did we sell it"). Columns: serial_number, item_code, item_description, doc_date, doc_id, entity_kind, entity (customer or supplier name), is_cancelled, warranty_years, serial_status.
-- params: serial=5CD, limit=50
SELECT m.serial_number, m.item_code, m.item_description, m.doc_date, m.doc_id, m.entity_kind,
       CASE m.entity_kind WHEN 'customer' THEN c.name WHEN 'supplier' THEN s.name END AS entity,
       m.is_cancelled, m.warranty_years, m.serial_status_flag
FROM serial_movements m
LEFT JOIN customers c ON m.entity_kind = 'customer' AND c.customer_code = m.entity_code
LEFT JOIN suppliers s ON m.entity_kind = 'supplier' AND s.supplier_code = m.entity_code
WHERE length(trim(:serial)) >= 3 AND lower(m.serial_number) LIKE '%' || lower(trim(:serial)) || '%'
ORDER BY m.serial_number, m.doc_date, m.doc_id
LIMIT :limit

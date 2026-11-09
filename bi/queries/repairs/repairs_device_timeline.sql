-- name: repairs_device_timeline
-- description: Full history of ONE device or part by serial number (case-insensitive; exact match, or substring match when exact=0, min 5 chars): purchase from the supplier, sale to the customer, credit notes/returns, use as a spare part in a repair, loans, quotes (serial_history = lin_mov_series 2017+ and older repair-part serials), every repair order opened for that serial (repairs view: status, equipment, customer) and supplier RMAs (repair_rmas). One row per event, oldest first: event_date, event, doc_id, item/equipment, entity (customer or supplier), detail. show_notes=1 adds the technician's diagnosis/work done (first 200 chars) for the repair orders of this device only - never the customer's fault text (often contains passwords).
-- params: serial=, exact=1, show_notes=0
SELECT * FROM (
  SELECT h.movement_date AS event_date, h.movement AS event, h.doc_id, h.serial_number, h.item_code,
         h.item_description AS item_or_equipment, h.entity_kind, h.entity_code, h.entity_name,
         CASE WHEN h.is_cancelled = 1 THEN 'documento anulado' WHEN h.is_credited = 1 THEN 'linha creditada' END AS detail
  FROM serial_history h
  WHERE length(lower(trim(:serial))) >= 3 AND (h.serial_key = lower(trim(:serial)) OR (:exact = 0 AND length(lower(trim(:serial))) >= 5 AND h.serial_key LIKE '%' || lower(trim(:serial)) || '%'))
  UNION ALL
  SELECT r.opened_on, 'repair_order', r.repair_id, r.serial_number, r.equipment_item,
         trim(COALESCE(r.equipment_type, r.equipment_type_code) || ' ' || COALESCE(r.brand_name, '') || ' ' || COALESCE(r.model, '')),
         'customer', r.customer_code, r.customer_name,
         'estado ' || r.status_code || COALESCE(' | valor ordem ' || ROUND(r.quoted_net, 2), '')
           || CASE WHEN :show_notes = 1 THEN COALESCE(' | diag: ' || substr(r.diagnosis, 1, 200), '') || COALESCE(' | feito: ' || substr(r.work_done, 1, 200), '') ELSE '' END
  FROM repairs r
  WHERE length(lower(trim(:serial))) >= 3 AND (lower(trim(r.serial_number)) = lower(trim(:serial)) OR (:exact = 0 AND length(lower(trim(:serial))) >= 5 AND lower(r.serial_number) LIKE '%' || lower(trim(:serial)) || '%'))
  UNION ALL
  SELECT m.opened_on, 'supplier_rma_' || m.status, 'RMA ' || m.rma_number, m.serial_number, m.item_code, m.item_description,
         'supplier', m.supplier_code, m.supplier_name,
         'ordem ' || COALESCE(m.repair_id, '-') || ' | enviado ' || COALESCE(m.shipped_on, '-') || ' | regressou ' || COALESCE(m.received_back_on, '-')
  FROM repair_rmas m
  WHERE length(lower(trim(:serial))) >= 3 AND (lower(m.serial_number) = lower(trim(:serial)) OR (:exact = 0 AND length(lower(trim(:serial))) >= 5 AND lower(m.serial_number) LIKE '%' || lower(trim(:serial)) || '%'))
) ORDER BY event_date, event
LIMIT 200

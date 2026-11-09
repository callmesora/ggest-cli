-- name: repairs_warranty_orders
-- description: Repair orders opened in a period for devices the shop sold and that were still under warranty when they came in (repair_warranty: serial matched to a sales invoice; term from the serial registry, 24 months when missing). Per order: repair id, opened date, status, equipment, customer on the order vs customer the device was sold to, sale date and document, warranty end, days of warranty left at opening, value typed on the order (net), whether a supplier RMA exists for the order, and the supplier the device was bought from (for an RMA claim). Use to check warranty jobs are not charged and are claimed from the supplier. No free text.
-- params: start=last_year_start, end=today, limit=200
SELECT w.repair_id, w.opened_on, w.status_code, COALESCE(w.equipment_type, w.equipment_type_code) AS equipment,
       w.brand_name, w.serial_number, w.customer_code, w.customer_name, w.sold_to_customer_code, w.same_customer,
       w.sold_on, w.sale_doc_id, w.warranty_months, w.warranty_end,
       CAST(julianday(w.warranty_end) - julianday(w.opened_on) AS INTEGER) AS warranty_days_left_at_opening,
       ROUND(w.quoted_net, 2) AS order_net,
       w.repair_id IN (SELECT origem_int_codigo||' '||origem_int_serie||'/'||origem_int_numero FROM assTec_RMA) AS has_supplier_rma,
       (SELECT trim(f.descricao) FROM Fornecedores f WHERE f.Codigo = p.supplier_code) AS bought_from_supplier
FROM repair_warranty w
LEFT JOIN (SELECT lower(trim(Serie_Artigo)) AS k, max(Entidade) AS supplier_code FROM lin_mov_series
           WHERE Codigo IN ('VFT','FTINC','FTEXC') AND estado_doc <> '1' GROUP BY 1) p ON p.k = lower(w.serial_number)
WHERE w.in_warranty = 1 AND w.opened_on BETWEEN :start AND :end
ORDER BY w.opened_on DESC
LIMIT :limit

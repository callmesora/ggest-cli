-- name: repairs_open_backlog
-- description: Repair orders not closed (status ABR aberta, INT em intervencao, PRO pronta em testes) with age in days at as_of, age band, equipment, customer, order value (net) and whether the order was already invoiced (sales line converted from this OSA) or the customer bought anything since opening. Old PRO orders are usually ready-but-never-collected or simply never closed in gGest. Filter with status = all | ABR | INT | PRO and min_age_days. No fault text (it often contains customer passwords).
-- params: as_of=2026-11-08, status=all, min_age_days=0, limit=200
WITH o AS (
  SELECT r.repair_id, r.opened_on, r.status_code, r.status, r.equipment_type_code, r.equipment_type, r.brand_name, r.model,
         r.customer_code, r.customer_name, r.quoted_net,
         CAST(julianday(:as_of) - julianday(r.opened_on) AS INTEGER) AS age_days
  FROM repairs r
  WHERE r.status_code IN ('ABR','INT','PRO') AND (:status = 'all' OR r.status_code = :status))
SELECT repair_id, opened_on, age_days,
       CASE WHEN age_days <= 7 THEN '0-7d' WHEN age_days <= 30 THEN '8-30d' WHEN age_days <= 90 THEN '31-90d'
            WHEN age_days <= 365 THEN '91-365d' ELSE '>1 ano' END AS age_band,
       status_code, status, equipment_type, brand_name, model, customer_code, customer_name,
       ROUND(quoted_net, 2) AS order_net,
       EXISTS (SELECT 1 FROM sales_facts f WHERE f.origin_doc_id = o.repair_id) AS invoiced_from_order,
       (SELECT MAX(f.doc_date) FROM sales_facts f WHERE f.customer_code = o.customer_code AND f.doc_date >= o.opened_on) AS last_purchase_since_opening
FROM o WHERE age_days >= :min_age_days
ORDER BY age_days DESC
LIMIT :limit

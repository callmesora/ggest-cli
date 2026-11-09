-- name: repairs_open_backlog
-- description: Repair orders not closed (status ABR aberta, INT em intervencao, PRO pronta em testes) with age in days at as_of, age band, days since the order was last changed in gGest (last_activity = alterado_data), equipment, customer, order value (net), whether it was already invoiced from the order (OSA conversion) and the customer's last purchase since opening. probably_closed = 1 for PRO orders with no change for more than stale_days or already invoiced: delivered/finished but never closed in gGest (gGest hygiene, not a pickup to chase). view = active (default: hides probably_closed, i.e. real work in progress and recent ready-for-pickup) | stale (only probably_closed, for cleanup) | all. Filter with status = all | ABR | INT | PRO and min_age_days. Sorted: PRO most recent first (call list), then oldest ABR/INT. No fault text (it often contains customer passwords).
-- params: as_of=today, status=all, view=active, stale_days=60, min_age_days=0, limit=200
WITH act AS (
  SELECT c.Codigo || ' ' || c.serie || '/' || c.numero AS repair_id, c.ano AS series_year,
         CASE WHEN c.alterado_data > '19000000' THEN date(substr(c.alterado_data,1,4)||'-'||substr(c.alterado_data,5,2)||'-'||substr(c.alterado_data,7,2)) END AS changed_on
  FROM Cab_Assistec c WHERE upper(c.Estado_Codigo) IN ('ABR','INT','PRO')),
inv AS MATERIALIZED (SELECT DISTINCT origin_doc_id FROM sales_facts WHERE origin_doc_type = 'OSA'),
o AS (
  SELECT r.repair_id, r.opened_on, r.status_code, r.status, r.equipment_type_code, r.equipment_type, r.brand_name, r.model,
         r.customer_code, r.customer_name, r.quoted_net,
         CAST(julianday(:as_of) - julianday(r.opened_on) AS INTEGER) AS age_days,
         MAX(r.opened_on, COALESCE(a.changed_on, r.opened_on)) AS last_activity,
         r.repair_id IN (SELECT origin_doc_id FROM inv) AS invoiced_from_order
  FROM repairs r JOIN act a ON a.repair_id = r.repair_id AND a.series_year = r.series_year
  WHERE r.status_code IN ('ABR','INT','PRO') AND (:status = 'all' OR r.status_code = :status)),
f AS (
  SELECT o.*, CAST(julianday(:as_of) - julianday(last_activity) AS INTEGER) AS days_since_activity,
         CASE WHEN status_code = 'PRO' AND (julianday(:as_of) - julianday(last_activity) > :stale_days OR invoiced_from_order = 1)
              THEN 1 ELSE 0 END AS probably_closed
  FROM o WHERE age_days >= :min_age_days)
SELECT repair_id, opened_on, age_days,
       CASE WHEN age_days <= 7 THEN '0-7d' WHEN age_days <= 30 THEN '8-30d' WHEN age_days <= 90 THEN '31-90d'
            WHEN age_days <= 365 THEN '91-365d' ELSE '>1 ano' END AS age_band,
       status_code, status, probably_closed, last_activity, days_since_activity,
       equipment_type, brand_name, model, customer_code, customer_name,
       ROUND(quoted_net, 2) AS order_net, invoiced_from_order,
       (SELECT MAX(s.doc_date) FROM sales_facts s WHERE s.customer_code = f.customer_code AND s.doc_date >= f.opened_on) AS last_purchase_since_opening
FROM f
WHERE :view = 'all' OR (:view = 'active' AND probably_closed = 0) OR (:view = 'stale' AND probably_closed = 1)
ORDER BY CASE WHEN status_code = 'PRO' AND probably_closed = 0 THEN 0 ELSE 1 END,
         CASE WHEN status_code = 'PRO' AND probably_closed = 0 THEN age_days ELSE -age_days END
LIMIT :limit

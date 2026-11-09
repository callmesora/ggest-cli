-- name: repairs_desk_summary
-- description: Repair desk morning check in one table. One row per open status (ABR aberta, INT em intervencao, PRO pronta em testes = ready, waiting for pickup/closing) with order count by age band at as_of (0-7d, 8-30d, 31-90d, 91-365d, >1y), oldest order date, order value (net, value typed on the order) and how many were already invoiced from the order and probably_closed (PRO with no change in gGest for more than stale_days or already invoiced = delivered but never closed; the rest of PRO = really waiting for pickup); plus intake rows: orders opened in the last 1/7/30 days and the same 30 days a year earlier. Age = days since opening (gGest does not record promised dates; close dates are not recorded since 2020). Use repairs_open_backlog for the order list.
-- params: as_of=today, stale_days=60
WITH o AS (
  SELECT r.repair_id, r.status_code, r.quoted_net,
         CAST(julianday(:as_of) - julianday(r.opened_on) AS INTEGER) AS age, r.opened_on,
         (SELECT MAX(r.opened_on, COALESCE(CASE WHEN c.alterado_data > '19000000' THEN date(substr(c.alterado_data,1,4)||'-'||substr(c.alterado_data,5,2)||'-'||substr(c.alterado_data,7,2)) END, r.opened_on))
            FROM Cab_Assistec c WHERE c.Codigo || ' ' || c.serie || '/' || c.numero = r.repair_id AND c.ano = r.series_year
              AND upper(c.Estado_Codigo) IN ('ABR','INT','PRO')) AS last_activity
  FROM repairs r WHERE r.status_code IN ('ABR','INT','PRO') AND r.opened_on <= :as_of),
inv AS (SELECT DISTINCT origin_doc_id FROM sales_facts WHERE origin_doc_type = 'OSA')
SELECT 'open' AS section, status_code AS item,
       CASE status_code WHEN 'ABR' THEN 'aberta' WHEN 'INT' THEN 'em intervencao' WHEN 'PRO' THEN 'pronta (levantar/fechar)' END AS meaning,
       COUNT(*) AS orders, SUM(age <= 7) AS d0_7, SUM(age BETWEEN 8 AND 30) AS d8_30, SUM(age BETWEEN 31 AND 90) AS d31_90,
       SUM(age BETWEEN 91 AND 365) AS d91_365, SUM(age > 365) AS over_1y, MIN(opened_on) AS oldest,
       ROUND(SUM(quoted_net), 2) AS order_net, SUM(repair_id IN (SELECT origin_doc_id FROM inv)) AS invoiced_from_order,
       SUM(status_code = 'PRO' AND (julianday(:as_of) - julianday(last_activity) > :stale_days OR repair_id IN (SELECT origin_doc_id FROM inv))) AS probably_closed
FROM o GROUP BY status_code
UNION ALL
SELECT 'intake', p.k, p.label,
       (SELECT COUNT(*) FROM repairs WHERE opened_on > date(:as_of, p.d0) AND opened_on <= date(:as_of, p.d1)),
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM (SELECT 'last_1d' AS k, 'abertas hoje (as_of)' AS label, '-1 days' AS d0, '+0 days' AS d1
      UNION ALL SELECT 'last_7d', 'ultimos 7 dias', '-7 days', '+0 days'
      UNION ALL SELECT 'last_30d', 'ultimos 30 dias', '-30 days', '+0 days'
      UNION ALL SELECT 'last_30d_ly', 'mesmos 30 dias ha um ano', '-395 days', '-365 days') p

-- name: repairs_workload_by_user
-- description: Workload per person per year (grain=year) or month (grain=month): repair orders opened (created_by_user = gGest user who typed the order, the best proxy since 2020), orders by receiving person (received_by_code, Cab_Assistec.Tecnico, mostly 0 since 2021) and by repairing technician (repair_technician_code from the intervention, recorded only until 2020-03), plus orders still open now. role = created_by | received_by | technician. User names from utilizadores (front desk users), technician names from assTec_tecnicos. Repair technician is NOT recorded since 2020: workload per technician cannot be measured for recent years.
-- params: start=last_year_start, end=today, grain=year, role=created_by
WITH r AS (
  SELECT CASE WHEN :grain = 'month' THEN month ELSE CAST(year AS TEXT) END AS period,
         CASE :role WHEN 'received_by' THEN received_by_code WHEN 'technician' THEN repair_technician_code ELSE created_by_user END AS who,
         status_code
  FROM repairs WHERE opened_on BETWEEN :start AND :end)
SELECT r.period, :role AS role, COALESCE(r.who, '0') AS code,
       COALESCE(CASE WHEN :role = 'created_by' THEN (SELECT trim(u.descricao) FROM utilizadores u WHERE u.Codigo = r.who)
                     ELSE (SELECT trim(t.descricao) FROM assTec_tecnicos t WHERE t.codigo = r.who) END,
                CASE WHEN COALESCE(r.who,'0') IN ('0','') THEN '(nao registado)' END) AS name,
       COUNT(*) AS orders, SUM(r.status_code IN ('ABR','INT','PRO')) AS still_open,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY r.period), 1) AS pct_of_period
FROM r GROUP BY r.period, r.who
ORDER BY r.period, orders DESC
LIMIT 500

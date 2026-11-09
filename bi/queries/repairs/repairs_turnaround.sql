-- name: repairs_turnaround
-- description: Turnaround (days from opening to closing the repair order) per year or per equipment group: orders, orders with a usable close date, coverage %, same-day %, <=7 days %, <=30 days %, average (0-365 d), median and p90 days. DATA QUALITY: close date (DataHora_Fecho) is only recorded 2011-2019 (+ Jan-Mar 2020); 2008-2010 and 2021+ have none, and a few rows close before they open (excluded). by = year | equipment.
-- params: start=2011-01-01, end=2019-12-31, by=year
WITH r AS MATERIALIZED (
  SELECT CASE WHEN :by = 'equipment' THEN
           CASE WHEN equipment_type_code = 'not' THEN 'notebook' WHEN equipment_type_code IN ('des','all','min') THEN 'desktop'
                WHEN equipment_type_code IN ('imp','sca') THEN 'impressora' WHEN equipment_type_code IN ('tab','ipa','pda','tel') THEN 'tablet_telemovel'
                ELSE 'outro' END
         ELSE CAST(year AS TEXT) END AS grp,
         julianday(closed_at) - julianday(opened_on) AS d
  FROM repairs WHERE opened_on BETWEEN :start AND :end),
v AS (SELECT grp, d, ROW_NUMBER() OVER (PARTITION BY grp ORDER BY d) AS rn, COUNT(*) OVER (PARTITION BY grp) AS cnt
      FROM r WHERE d >= 0 AND d <= 365),
pct AS (SELECT grp, MIN(CASE WHEN rn >= 0.5 * cnt THEN d END) AS median_days, MIN(CASE WHEN rn >= 0.9 * cnt THEN d END) AS p90_days
        FROM v GROUP BY grp)
SELECT r.grp AS grp, COUNT(*) AS repairs, SUM(d IS NOT NULL) AS with_close_date,
       ROUND(100.0 * SUM(d IS NOT NULL) / COUNT(*), 1) AS close_date_coverage_pct,
       SUM(d < 0) AS closed_before_opened,
       ROUND(100.0 * SUM(d >= 0 AND d < 1) / NULLIF(SUM(d >= 0), 0), 1) AS same_day_pct,
       ROUND(100.0 * SUM(d >= 0 AND d <= 7) / NULLIF(SUM(d >= 0), 0), 1) AS within_7d_pct,
       ROUND(100.0 * SUM(d >= 0 AND d <= 30) / NULLIF(SUM(d >= 0), 0), 1) AS within_30d_pct,
       ROUND(AVG(CASE WHEN d >= 0 AND d <= 365 THEN d END), 1) AS avg_days,
       ROUND(MAX(pct.median_days), 1) AS median_days, ROUND(MAX(pct.p90_days), 1) AS p90_days
FROM r LEFT JOIN pct ON pct.grp = r.grp
GROUP BY r.grp ORDER BY r.grp
